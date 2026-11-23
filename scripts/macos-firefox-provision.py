#!/usr/bin/env python3
"""Install the signed Mozilla app in the user's Applications directory."""

import ctypes
import errno
import fcntl
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


IDENTIFIER = "org.mozilla.firefoxdeveloperedition"
APP_NAME = "Firefox Developer Edition.app"
DOWNLOAD = "https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=osx&lang=ko"
REQUIREMENT = f'=anchor apple generic and identifier "{IDENTIFIER}" and certificate leaf[subject.OU] = "43AQ936H96"'


def official(app):
    try:
        with (app / "Contents/Info.plist").open("rb") as file:
            if plistlib.load(file).get("CFBundleIdentifier") != IDENTIFIER:
                return False
        return subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, str(app)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
        ).returncode == 0
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.TimeoutExpired):
        return False


def writable(app):
    return os.access(app, os.W_OK) and os.access(app / "Contents/MacOS/firefox", os.W_OK)


def candidates(destination):
    yield destination
    yield Path("/Applications") / APP_NAME
    try:
        result = subprocess.run(
            ["/usr/bin/mdfind", f'kMDItemCFBundleIdentifier == "{IDENTIFIER}"'],
            capture_output=True,
            text=True,
            check=True,
            timeout=15,
        )
        for path in result.stdout.splitlines():
            app = Path(path)
            if app.is_relative_to(Path.home()):
                yield app
    except (OSError, subprocess.SubprocessError):
        pass


def publish(source, destination):
    # renamex_np with RENAME_EXCL refuses even an empty existing destination.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 4) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def provision(destination):
    existing = None
    for app in candidates(destination):
        if official(app):
            if writable(app):
                return app
            if existing is None:
                existing = app

    # Never replace an unrelated or incomplete user-owned path.
    if os.path.lexists(destination):
        raise FileExistsError(errno.EEXIST, "Destination already exists", str(destination))

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".firefox-developer-", dir=destination.parent) as staging:
        staged = Path(staging) / APP_NAME
        if existing:
            subprocess.run(["/usr/bin/ditto", str(existing), str(staged)], check=True, timeout=300)
        else:
            with tempfile.TemporaryDirectory(prefix="firefox-developer-") as download_dir:
                image = Path(download_dir) / "firefox.dmg"
                subprocess.run(
                    ["/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--max-time", "300", "--output", str(image), DOWNLOAD],
                    check=True,
                )
                mountpoint = Path(tempfile.mkdtemp(prefix="firefox-developer-mount-"))
                try:
                    subprocess.run(
                        ["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mountpoint), str(image)],
                        check=True,
                        timeout=120,
                    )
                    subprocess.run(["/usr/bin/ditto", str(mountpoint / APP_NAME), str(staged)], check=True, timeout=300)
                finally:
                    if os.path.ismount(mountpoint):
                        subprocess.run(["/usr/bin/hdiutil", "detach", str(mountpoint)], check=True, timeout=120)
                    # Never recursively remove a mount point, even after a failed detach.
                    mountpoint.rmdir()
        if not official(staged) or not writable(staged):
            raise RuntimeError("Downloaded Firefox bundle failed signature or writable checks")
        publish(staged, destination)
    return destination


def main():
    if os.geteuid() == 0:
        raise RuntimeError("Firefox provisioning must run as the desktop user")
    home = Path.home()
    state = home / ".local/state/nix-config"
    state.mkdir(parents=True, exist_ok=True)
    with (state / "firefox-developer.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        app = provision(home / "Applications" / APP_NAME)
        subprocess.run([sys.argv[1], str(app)], check=True, timeout=130)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Firefox Developer Edition: {error}", file=sys.stderr)
        sys.exit(1)
