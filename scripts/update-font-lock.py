"""Resolve desktop font releases and archive members without installing them."""

import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile


def github_release(repository):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", f"repos/{repository}/releases/latest"],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    return json.loads(result.stdout)


def download(url):
    request = Request(url, headers={"User-Agent": "dotfiles-font-lock"})
    with urlopen(request, timeout=120) as response:
        return response.read()


def selected_files(payload, format, selections):
    if not selections:
        raise ValueError("Expected at least one font selection")
    counts = [0] * len(selections)
    files = []
    destinations = set()

    def select(path, regular, read):
        matches = [i for i, selection in enumerate(selections)
                   if fnmatch.fnmatchcase(path, selection["pattern"])]
        if not matches:
            return
        if (not regular or path.startswith("/") or "\\" in path
                or any(part in ("", ".", "..") for part in path.split("/"))):
            raise ValueError(f"Expected a safe regular font member: {path}")
        name = PurePosixPath(path).name
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.ttf", name):
            raise ValueError(f"Expected a desktop TTF basename: {path}")
        if name.lower() in destinations:
            raise ValueError(f"Duplicate font destination: {name}")
        destinations.add(name.lower())
        for index in matches:
            counts[index] += 1
        files.append({"path": path, "name": name, "sha256": hashlib.sha256(read()).hexdigest()})

    if format == "zip":
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            for entry in archive.infolist():
                mode = stat.S_IFMT(entry.external_attr >> 16)
                select(entry.filename, not entry.is_dir() and mode in (0, stat.S_IFREG),
                       lambda entry=entry: archive.read(entry))
    elif format == "tar.xz":
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:xz") as archive:
            for entry in archive:
                select(entry.name, entry.isfile(),
                       lambda entry=entry: archive.extractfile(entry).read())
    else:
        raise ValueError(f"Unsupported font archive format: {format}")
    for selection, count in zip(selections, counts):
        minimum = selection["minimum"]
        if not isinstance(minimum, int) or minimum < 1 or count < minimum:
            raise ValueError(f"Font selection {selection['pattern']} needs at least {minimum} files; found {count}")
    return sorted(files, key=lambda font: font["path"])


def resolve_font(declaration, release, fetch_archive):
    repository = declaration["repository"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected a GitHub owner/repository")
    tag = release.get("tag_name") or ""
    version = re.fullmatch(r"(?:v|VER)?([0-9]+(?:\.[0-9]+){1,2})", tag)
    if not version or release.get("draft") is not False or release.get("prerelease") is not False:
        raise ValueError(f"{repository}: expected a published stable version")
    pattern = declaration["assetPattern"].replace("{version}", re.escape(version[1]))
    assets = [asset for asset in release["assets"] if re.fullmatch(pattern, asset["name"])]
    if len(assets) != 1:
        raise ValueError(f"{repository} {tag}: expected exactly one matching release asset")
    asset = assets[0]
    url = f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{quote(asset['name'], safe='')}"
    if asset.get("state") != "uploaded" or asset.get("browser_download_url") != url:
        raise ValueError(f"{repository} {tag}: unexpected release asset URL or upload state")
    payload = fetch_archive(url)
    checksum = hashlib.sha256(payload).hexdigest()
    digest = asset.get("digest")
    if digest is not None and digest != "sha256:" + checksum:
        raise ValueError(f"{repository} {tag}: downloaded asset checksum does not match GitHub digest")
    return {
        "repository": repository, "tag": tag, "url": url, "sha256": checksum,
        "format": declaration["format"],
        "files": selected_files(payload, declaration["format"], declaration["selections"]),
    }


def update_lock(root, fetch_release=github_release, fetch_archive=download):
    data_dir = root / "home/.chezmoidata"
    declarations = json.loads((data_dir / "fonts.json").read_text(encoding="utf-8"))["fonts"]
    releases = {}
    resolved = {}
    for name, declaration in declarations.items():
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            raise ValueError(f"Expected a safe font package identifier: {name}")
        repository = declaration["repository"]
        if repository not in releases:
            releases[repository] = fetch_release(repository)
        resolved[name] = resolve_font(declaration, releases[repository], fetch_archive)
    lock = {"fontLocks": resolved}
    lock_path = data_dir / "font-lock.json"
    if lock_path.exists() and json.loads(lock_path.read_text(encoding="utf-8")) == lock:
        print("Font pins are unchanged")
        return False
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="\n", dir=data_dir, delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, lock_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Updated font pins: " + ", ".join(f"{name} {pin['tag']}" for name, pin in resolved.items()))
    return True


if __name__ == "__main__":
    try:
        update_lock(Path(__file__).resolve().parents[1])
    except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
            OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        raise SystemExit(f"Font lock refresh failed: {error}") from error
