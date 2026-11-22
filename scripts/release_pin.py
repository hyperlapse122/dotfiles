"""Shared release metadata helpers."""

import base64
import json
import subprocess


class Failure(Exception):
    """A refusal that should stop the caller with a readable message."""


def fetch(url):
    """Fetch one URL with curl and return the raw body."""
    proc = subprocess.run(
        ["curl", "-sfL", "--max-time", "60", url],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise Failure(f"fetching {url} failed with status {proc.returncode}")
    return proc.stdout


def hex_to_sri(sha256_hex):
    """Convert a 64-character hex sha256 string to Nix SRI format."""
    return "sha256-" + base64.b64encode(bytes.fromhex(sha256_hex)).decode("ascii")


def pinned_version(path):
    """Return the version already pinned at path, or None when unreadable."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            current = json.load(f)
        return current.get("version")
    except Exception:
        return None


def version_tuple(version):
    if not isinstance(version, str):
        raise ValueError(f"not a version string: {version!r}")
    return tuple(int(part) for part in version.split("."))
