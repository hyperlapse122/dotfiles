import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote, unquote, urlsplit
from urllib.request import urlopen


CLAUDE_RELEASES = "https://downloads.claude.ai/claude-code-releases"


def claude_release():
    with urlopen(f"{CLAUDE_RELEASES}/latest", timeout=60) as response:
        version = response.read().decode("utf-8").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Claude: expected a stable version")
    with urlopen(f"{CLAUDE_RELEASES}/{version}/manifest.json", timeout=60) as response:
        return version, json.loads(response.read())


def resolve_claude_application(application, version, manifest):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version or "") or manifest.get("version") != version:
        raise ValueError("Claude: missing or mismatched stable manifest version")
    platforms = manifest.get("platforms")
    if not isinstance(platforms, dict):
        raise ValueError("Claude: expected a platform manifest")
    targets = {}
    for target, declaration in application["targets"].items():
        platform = declaration["platform"]
        expected_platform = target.replace("windows-", "win32-").replace("amd64", "x64")
        binary = "claude.exe" if target.startswith("windows-") else "claude"
        if (platform != expected_platform or declaration["kind"] != "file"
                or declaration["asset"] != binary):
            raise ValueError(f"Claude: unexpected target declaration for {target}")
        entry = platforms.get(platform)
        if not isinstance(entry, dict) or entry.get("binary") != binary:
            raise ValueError(f"Claude: missing platform or unexpected binary for {platform}")
        digest = entry.get("checksum") or ""
        if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise ValueError(f"Claude: missing SHA-256 checksum for {platform}")
        targets[target] = {"kind": "file", "sha256": digest.lower(),
                           "url": f"{CLAUDE_RELEASES}/{version}/{platform}/{binary}"}
    return {"tag": version, "targets": targets}


def github_release(repository):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", f"repos/{repository}/releases/latest"],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    return json.loads(result.stdout)


def gitlab_release(repository):
    url = f"https://gitlab.com/api/v4/projects/{quote(repository, safe='')}/releases/permalink/latest"
    with urlopen(url, timeout=60) as response:
        return json.loads(response.read())


def antigravity_manifest(target):
    url = (
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/"
        f"manifests/{target.replace('-', '_')}.json"
    )
    with urlopen(url, timeout=60) as response:
        return json.loads(response.read())


def resolve_antigravity(application, fetch_manifest):
    targets = {}
    version = None
    for target, declaration in application["targets"].items():
        manifest = fetch_manifest(target)
        if not isinstance(manifest, dict):
            raise ValueError(f"Antigravity {target}: expected an official manifest object")
        target_version = manifest.get("version") or ""
        if not isinstance(target_version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", target_version):
            raise ValueError(f"Antigravity {target}: expected a published stable version")
        if version is not None and target_version != version:
            raise ValueError("Antigravity manifests disagree on the stable version")
        version = target_version
        url = manifest.get("url") or ""
        expected_url = (
            r"https://storage\.googleapis\.com/antigravity-public/antigravity-cli/"
            + re.escape(version) + r"-\d+/" + re.escape(declaration["asset"])
        )
        if not isinstance(url, str) or not re.fullmatch(expected_url, url):
            raise ValueError(f"Antigravity {target}: unexpected versioned artifact URL")
        digest = manifest.get("sha512") or ""
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{128}", digest):
            raise ValueError(f"Antigravity {target}: missing SHA-512 digest")
        kind = declaration["kind"]
        if kind not in ("file", "archive-file"):
            raise ValueError(f"Antigravity {target}: unsupported installation kind {kind}")
        pin = {"kind": kind, "url": url, "sha512": digest.lower()}
        if kind == "archive-file":
            pin["format"] = declaration["format"]
            pin["path"] = declaration["path"]
        targets[target] = pin
    return {"tag": version, "targets": targets}


def gitlab_checksums(url):
    with urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8")


def release_asset_url(source, repository, tag, name):
    if source == "gitlab":
        return (
            f"https://gitlab.com/{repository}/-/releases/"
            f"{quote(tag, safe='')}/downloads/{quote(name, safe='')}"
        )
    return (
        f"https://github.com/{repository}/releases/download/"
        f"{quote(tag, safe='')}/{quote(name, safe='')}"
    )


def normalize_gitlab_release(application, release, fetch_checksums):
    repository = application["repository"]
    tag = release["tag_name"]
    if release.get("upcoming_release") or not re.fullmatch(r"v?\d+\.\d+\.\d+", tag or ""):
        raise ValueError(f"{repository}: expected a published stable release")
    version = tag.removeprefix("v")
    links = release["assets"]["links"]
    names = [expand_version(target["asset"], version) for target in application["targets"].values()]
    assets = {}
    for name in dict.fromkeys([*names, "checksums.txt"]):
        matches = [link for link in links if link.get("name") == name]
        if len(matches) != 1:
            raise ValueError(f"{repository} {tag}: expected one asset named {name}")
        link = matches[0]
        expected_url = release_asset_url("gitlab", repository, tag, name)
        if link.get("direct_asset_url") != expected_url:
            raise ValueError(f"{repository} {tag}: unexpected release URL for {name}")
        # GitLab's official release redirect points into the project's package registry.
        package_url = urlsplit(link.get("url") or "")
        expected_path = (
            f"/api/v4/projects/{repository}/packages/generic/"
            f"{application['command']}/{version}/{name}"
        )
        if (
            package_url.scheme != "https" or package_url.netloc != "gitlab.com"
            or unquote(package_url.path) != expected_path or package_url.query or package_url.fragment
        ):
            raise ValueError(f"{repository} {tag}: unexpected package URL for {name}")
        assets[name] = {"name": name, "browser_download_url": expected_url, "state": "uploaded"}

    checksums = {}
    manifest = fetch_checksums(assets["checksums.txt"]["browser_download_url"])
    for line in manifest.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](\S+)", line)
        if not match or match[2] in checksums:
            raise ValueError(f"{repository} {tag}: malformed or duplicate SHA-256 checksum")
        checksums[match[2]] = match[1].lower()
    normalized = []
    for name in dict.fromkeys(names):
        if name not in checksums:
            raise ValueError(f"{repository} {tag}: missing SHA-256 digest for {name}")
        normalized.append({**assets[name], "digest": "sha256:" + checksums[name]})
    return {"tag_name": tag, "assets": normalized}


def expand_version(pattern, version):
    expanded = pattern.replace("{version}", version)
    if "{" in expanded or "}" in expanded:
        raise ValueError("Personal application patterns support only {version}")
    return expanded


def resolve_application(application, release):
    repository = application["repository"]
    tag = release["tag_name"]
    if not tag or release.get("draft") or release.get("prerelease"):
        raise ValueError(f"{repository}: expected a published stable release")

    version = tag.removeprefix("v")
    targets = {}
    for target, declaration in application["targets"].items():
        name = expand_version(declaration["asset"], version)
        kind = declaration["kind"]
        if kind not in ("file", "archive-file"):
            raise ValueError(f"{repository}: unsupported installation kind {kind}")
        pin = {"kind": kind}
        if kind == "archive-file":
            pin["format"] = declaration["format"]
            pin["path"] = expand_version(declaration["path"], version)
            if "stripComponents" in declaration:
                pin["stripComponents"] = declaration["stripComponents"]
        matches = [asset for asset in release["assets"] if asset["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"{repository} {tag}: expected one asset named {name}")
        asset = matches[0]
        digest = asset.get("digest") or ""
        if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
            raise ValueError(f"{repository} {tag}: missing SHA-256 digest for {name}")
        expected_url = release_asset_url(application.get("source", "github"), repository, tag, name)
        if asset["browser_download_url"] != expected_url:
            raise ValueError(f"{repository} {tag}: unexpected release URL for {name}")
        if asset.get("state") != "uploaded":
            raise ValueError(f"{repository} {tag}: asset {name} is not fully uploaded")
        targets[target] = {**pin, "url": expected_url, "sha256": digest[7:].lower()}
    return {"tag": tag, "targets": targets}


def update_lock(
    root, fetch_release=github_release, *, fetch_gitlab_release=gitlab_release,
    fetch_checksums=gitlab_checksums, fetch_manifest=antigravity_manifest,
    fetch_claude_release=claude_release,
):
    data_dir = root / "home" / ".chezmoidata"
    applications = json.loads((data_dir / "personal-apps.json").read_text(encoding="utf-8"))["personalApps"]
    resolved = {}
    for name, application in applications.items():
        source = application.get("source", "github")
        if source == "antigravity":
            resolved[name] = resolve_antigravity(application, fetch_manifest)
            continue
        if source not in ("github", "gitlab", "claude"):
            raise ValueError(f"{name}: unsupported release source {source}")
        repository = application["repository"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError(f"{name}: expected an owner/repository")
        if source == "claude":
            version, manifest = fetch_claude_release()
            resolved[name] = resolve_claude_application(application, version, manifest)
            continue
        if source == "gitlab":
            release = normalize_gitlab_release(application, fetch_gitlab_release(repository), fetch_checksums)
        else:
            release = fetch_release(repository)
        resolved[name] = resolve_application(application, release)
    lock = {"personalAppLocks": resolved}
    lock_path = data_dir / "personal-app-lock.json"
    if lock_path.exists() and json.loads(lock_path.read_text(encoding="utf-8")) == lock:
        print("Personal application pins are unchanged")
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
    print("Updated personal application pins: " + ", ".join(f"{name} {pin['tag']}" for name, pin in resolved.items()))
    return True


if __name__ == "__main__":
    try:
        update_lock(Path(__file__).resolve().parents[1])
    except (ValueError, KeyError, subprocess.SubprocessError, OSError) as error:
        raise SystemExit(f"Personal application lock refresh failed: {error}") from error
