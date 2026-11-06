import base64
import configparser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
from urllib.parse import quote
from urllib.request import urlopen


def github_json(endpoint):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", endpoint],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    return json.loads(result.stdout)


def download_archive(url):
    with urlopen(url, timeout=60) as response:
        return response.read()


def repository_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ValueError("Expected a GitHub owner/repository")
    return value


def commit_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise ValueError("Expected a full Git commit pin")
    return value.lower()


def relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value:
        raise ValueError(f"Invalid submodule path: {value!r}")
    return value


def resolve_archives(repository, commit, selected, fetch, download, prefix="", ancestors=()):
    repository = repository_name(repository)
    commit = commit_sha(commit)
    identity = repository, commit
    if identity in ancestors:
        raise ValueError(f"Cyclic submodule dependency: {repository} {commit}")
    url = f"https://codeload.github.com/{repository}/tar.gz/{commit}"
    payload = download(url)
    if not payload:
        raise ValueError(f"Empty archive: {repository} {commit}")
    archives = [{"path": prefix, "repository": repository, "commit": commit,
                 "url": url, "sha256": hashlib.sha256(payload).hexdigest()}]
    base = f"repos/{repository}"
    tree = fetch(f"{base}/git/trees/{commit}?recursive=1")
    if tree.get("truncated"):
        raise ValueError(f"Incomplete Git tree: {repository} {commit}")
    gitlinks = {relative_path(item["path"]): commit_sha(item["sha"])
                for item in tree["tree"] if item.get("mode") == "160000"}
    paths = sorted(gitlinks) if selected is None else selected
    for path in paths:
        relative_path(path)
        if path not in gitlinks:
            raise ValueError(f"Missing required submodule: {repository} {path}")
    if not paths:
        return archives
    document = fetch(f"{base}/contents/.gitmodules?ref={commit}")
    modules = configparser.ConfigParser(interpolation=None)
    modules.read_string(base64.b64decode(document["content"]).decode("utf-8"))
    repositories = {}
    for section in modules.sections():
        path = modules.get(section, "path")
        if path not in paths:
            continue
        url_match = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", modules.get(section, "url"))
        if not url_match:
            raise ValueError(f"Expected official GitHub submodule URL for {path}")
        repositories[path] = url_match[1]
    for path in paths:
        if path not in repositories:
            raise ValueError(f"Missing submodule repository: {repository} {path}")
        target = f"{prefix}/{path}" if prefix else path
        archives.extend(resolve_archives(repositories[path], gitlinks[path], None, fetch, download,
                                         target, (*ancestors, identity)))
    return archives


def update_lock(root, fetch=github_json, download=download_archive):
    data_dir = root / "home/.chezmoidata"
    manifest = json.loads((data_dir / "zsh.json").read_text(encoding="utf-8"))["zsh"]
    repository = repository_name(manifest["repository"])
    commit = fetch(f"repos/{repository}/commits/{quote(manifest['ref'], safe='')}")["sha"]
    archives = resolve_archives(repository, commit, manifest["submodules"], fetch, download)
    lock = {"zshLock": {"archives": archives}}
    lock_path = data_dir / "zsh-lock.json"
    if lock_path.exists() and json.loads(lock_path.read_text(encoding="utf-8")) == lock:
        print("Zsh pins are unchanged")
        return False
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=data_dir, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(lock, indent=2) + "\n")
        os.replace(temporary, lock_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Updated Prezto {commit}: {len(archives)} pinned archives")
    return True


if __name__ == "__main__":
    try:
        update_lock(Path(__file__).resolve().parents[1])
    except (ValueError, KeyError, TypeError, AttributeError, configparser.Error, subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"Zsh lock refresh failed: {error}") from error
