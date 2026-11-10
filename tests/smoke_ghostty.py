"""Prove Ghostty installation and native interfaces on disposable hosted runners.

This does not prove graphical launches, password entry, or macOS approval UI.
Linux account changes use a temporary account; macOS associations are read only.
"""

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import platform
import secrets
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
DESKTOP_ID = "com.mitchellh.ghostty.desktop"


def run(arguments, *, accepted=(0,), env=None):
    result = subprocess.run([str(item) for item in arguments], env=env,
                            capture_output=True, text=True, encoding="utf-8",
                            errors="replace", timeout=600)
    if result.returncode not in accepted:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments!r}\n"
                           + result.stdout + result.stderr)
    return result


def target():
    architecture = {"x86_64": "amd64", "AMD64": "amd64",
                    "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    operating_system = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    selected = f"{operating_system}-{architecture}"
    if selected not in ("linux-amd64", "darwin-arm64"):
        raise RuntimeError(f"Unsupported native Ghostty target: {selected}")
    return selected


@contextmanager
def disposable_account(root):
    username = "dotfiles-ghostty-" + secrets.token_hex(4)
    home = root / "account"
    run(["sudo", "useradd", "--create-home", "--home-dir", home,
         "--shell", "/bin/bash", username])
    try:
        yield username, home
    finally:
        run(["sudo", "userdel", "--remove", username])


def as_account(username, home, arguments):
    return ["sudo", "--user", username, "--", "env", "HOME=" + str(home),
            "XDG_CONFIG_HOME=" + str(home / ".config"), "SHELL=/bin/zsh",
            "PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "XDG_CURRENT_DESKTOP=KDE", "XDG_SESSION_TYPE=", *arguments]


def verify_terminal_status(status):
    pending = [line for line in status.stderr.splitlines()
               if line.startswith("Terminal environment PENDING:")]
    allowed = {
        "Terminal environment PENDING: The systemd user-manager environment is unavailable; verify in a desktop session.",
        "Terminal environment PENDING: Native KDE Plasma acceptance remains unverified: check Default Applications, Ctrl+Alt+T, Dolphin Open Terminal Here, and a Terminal=true launcher in a fresh desktop session.",
    }
    if status.returncode == 0 and not pending:
        return
    if status.returncode != 2 or not pending or set(pending) - allowed:
        raise RuntimeError("Unexpected native terminal state:\n" + status.stdout + status.stderr)


def fedora_smoke(selected, root):
    run(["python3", REPO / "scripts/linux-platform.py"])
    version = platform.freedesktop_os_release()["VERSION_ID"]
    architecture = selected.split("-", 1)[1]
    run(["/bin/sh", REPO / "scripts/install-ghostty.sh", version, architecture])
    ghostty = shutil.which("ghostty")
    if not ghostty:
        raise RuntimeError("Native installation did not expose Ghostty on PATH")
    print(run([ghostty, "--version"]).stdout.strip())
    desktop = Path("/usr/share/applications") / DESKTOP_ID
    metadata = desktop.read_text(encoding="utf-8")
    for field in ("Type=Application", "X-TerminalArgExec=-e", "X-TerminalArgDir=--working-directory="):
        if field not in metadata:
            raise RuntimeError(f"Native Ghostty desktop metadata is missing {field}")

    helper = root / "terminal-environment.sh"
    configuration = root / "ghostty-config"
    shutil.copy2(REPO / "scripts/terminal-environment.sh", helper)
    shutil.copy2(REPO / "scripts/linux-platform.py", root / "linux-platform.py")
    shutil.copy2(REPO / "home/.chezmoitemplates/ghostty-config", configuration)
    root.chmod(0o755)
    helper.chmod(0o644)
    configuration.chmod(0o644)
    with disposable_account(root) as (username, home):
        # Authentication UI is not automated: an administrator changes only the
        # disposable account, then the real non-root reconciler runs as that user.
        run(["sudo", "chsh", "--shell", "/bin/zsh", username])
        record = run(["getent", "passwd", username]).stdout.strip().split(":")
        if record[-1] != "/bin/zsh":
            raise RuntimeError("Native chsh did not update the disposable account")
        arguments = ["/bin/sh", helper, "apply", "linux", architecture,
                     version, home, "unused-swift-helper", configuration]
        applied = run(as_account(username, home, arguments))
        print(applied.stdout.strip())
        status = run(as_account(username, home, [*arguments[:2], "status", *arguments[3:]]),
                     accepted=(0, 2))
        verify_terminal_status(status)
        command = next(line[5:] for line in metadata.splitlines() if line.startswith("Exec="))
        for key, expected in (("TerminalService", DESKTOP_ID), ("TerminalApplication", command)):
            value = run(as_account(username, home, ["kreadconfig6", "--file", "kdeglobals",
                                                    "--group", "General", "--key", key])).stdout.strip()
            if value != expected:
                raise RuntimeError(f"KDE {key} selected {value!r}")
        print("Native account/default/configuration probes passed; desktop launch remains untested.")


def macos_smoke(root):
    run(["/bin/sh", REPO / "scripts/macos-apps.sh", "cask:ghostty"])
    applications = (Path("/Applications/Ghostty.app"), Path.home() / "Applications/Ghostty.app")
    executable = next((app / "Contents/MacOS/ghostty" for app in applications
                       if os.access(app / "Contents/MacOS/ghostty", os.X_OK)), None)
    if executable is None:
        raise RuntimeError("Native Ghostty cask did not expose an executable application bundle")
    print(run([executable, "--version"]).stdout.strip())
    helper = root / "ghostty-default-terminal"
    run(["swiftc", "-module-cache-path", root / "module-cache",
         REPO / "scripts/ghostty-default-terminal.swift", "-o", helper])
    result = run([helper, "status", Path.home()], accepted=(0, 2))
    print(result.stdout.strip())
    print("Native AppKit helper compiled and queried; no default association was changed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise RuntimeError("Native Ghostty provisioning is restricted to disposable GitHub-hosted runners")
    selected = target()
    if args.expected_target and selected != args.expected_target:
        raise RuntimeError(f"Expected {args.expected_target}, detected {selected}")
    with tempfile.TemporaryDirectory(prefix="ghostty-native-") as temporary:
        root = Path(temporary).resolve()
        if selected.startswith("linux-"):
            fedora_smoke(selected, root)
        else:
            macos_smoke(root)


if __name__ == "__main__":
    main()
