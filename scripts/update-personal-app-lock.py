"""Resolve declared GitHub release assets through gh and update chezmoi pins."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote


def github_release(repository):
    result = subprocess.run(
        ["gh", "api", "--hostname", "github.com", f"repos/{repository}/releases/latest"],
        check=True, capture_output=True, text=True, encoding="utf-8", timeout=60,
    )
    return json.loads(result.stdout)


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
        expected_url = (
            f"https://github.com/{repository}/releases/download/"
            f"{quote(tag, safe='')}/{quote(name, safe='')}"
        )
        if asset["browser_download_url"] != expected_url:
            raise ValueError(f"{repository} {tag}: unexpected release URL for {name}")
        if asset.get("state") != "uploaded":
            raise ValueError(f"{repository} {tag}: asset {name} is not fully uploaded")
        targets[target] = {**pin, "url": expected_url, "sha256": digest[7:].lower()}
    return {"tag": tag, "targets": targets}


def update_lock(root, fetch_release=github_release):
    data_dir = root / "home" / ".chezmoidata"
    applications = json.loads((data_dir / "personal-apps.json").read_text(encoding="utf-8"))["personalApps"]
    resolved = {}
    for name, application in applications.items():
        repository = application["repository"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError(f"{name}: expected a GitHub owner/repository")
        resolved[name] = resolve_application(application, fetch_release(repository))
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
