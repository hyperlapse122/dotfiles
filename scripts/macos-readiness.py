"""Inspect local macOS prerequisites without applying settings or authenticating.

This snapshot cannot certify manual or runtime checks. Follow docs/setup/macos.md
to complete them. Exit 1 means failed checks; 2 means checks remain pending.
"""

import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess


COMMANDS = ("brew", "git", "mise", "chezmoi", "gpg", "gpgconf", "pinentry-mac",
            "claude", "codex", "omp", "agy", "gh", "glab", "ghq", "op",
            "t3", "python", "pwsh", "dotnet", "rustc", "cargo", "cmake", "ninja", "vcpkg")
MANAGED_FILES = {
    "Git configuration": ".gitconfig",
    "GPG agent configuration": ".gnupg/gpg-agent.conf",
    "Shell PATH fragment": ".config/dotfiles/path.sh",
    "Claude instructions": ".claude/CLAUDE.md",
    "Codex instructions": ".codex/AGENTS.md",
    "omp instructions": ".omp/agent/AGENTS.md",
    "Antigravity instructions": ".gemini/GEMINI.md",
    "T3 server preferences": ".t3/userdata/settings.json",
    "T3 client preferences": ".t3/userdata/client-settings.json",
    "System CA LaunchAgent": "Library/LaunchAgents/com.hyperlapse.native-system-ca.plist",
}


def probe(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15,
                                encoding="utf-8", errors="replace")
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def collect(home):
    checks = []

    def record(name, status, detail):
        checks.append({"name": name, "status": status, "detail": detail})

    version = platform.mac_ver()[0].split(".")[0]
    supported = (platform.system() == "Darwin" and platform.machine() == "arm64"
                 and version.isdigit() and int(version) >= 26)
    record("Supported host", "passed" if supported else "failed", "Requires native Apple Silicon macOS 26 or later.")
    if not supported:
        return {"ready": False, "checks": checks}

    commands = {command: shutil.which(command) for command in COMMANDS}
    for command, executable in commands.items():
        record("Command: " + command, "passed" if executable else "failed",
               "Available on this shell PATH." if executable else "Missing; complete prerequisites/apply and open a fresh shell.")
    for name, relative in MANAGED_FILES.items():
        record(name, "passed" if (home / relative).is_file() else "failed",
               "Managed file presence only; verify native discovery in the checklist.")
    for name, bundle in (("Chrome", "Google Chrome.app"), ("1Password", "1Password.app")):
        exists = any((root / bundle).is_dir() for root in (Path("/Applications"), home / "Applications"))
        record("Application: " + name, "passed" if exists else "pending",
               "Found application bundle." if exists else "Open the app or verify a custom Homebrew appdir manually.")
    if shutil.which("xcrun"):
        record("Apple compiler", "passed" if probe(["xcrun", "--find", "clang"]) is not None else "failed",
               "Clang lookup only; native build verification also checks the selected SDK.")
    else:
        record("Apple compiler", "failed", "Install and select Apple Command Line Tools.")
    if commands["dotnet"]:
        sdks = probe(["dotnet", "--list-sdks"])
        for major in (8, 10):
            present = sdks is not None and any(line.startswith(f"{major}.") for line in sdks.splitlines())
            record(f".NET SDK {major}", "passed" if present else "failed", "SDK inventory only; build/run remains a separate check.")

    for name, detail in (
        ("Native CE discovery", "Verify each harness discovers its native instructions and pinned CE skills; file presence is insufficient."),
        ("Authenticated CE invocation", "Sign in and invoke a CE skill through each harness; discovery is not model execution."),
        ("Signing and account authentication", "Verify a signed commit and real GitHub/GitLab operations using the intended key/accounts."),
        ("T3 and desktop runtime", "Open a project in T3 with each configured provider and launch the managed desktop apps."),
        ("Native builds and execution", "Run tests/smoke_macos_build_environment.py and inspect its native ARM64 report."),
        ("System CA session", "Verify organization trust and NODE_USE_SYSTEM_CA in a fresh desktop session."),
        ("Reapply and new worktree", "Reapply, then prepare another worktree and confirm personal settings remain unchanged during preparation."),
    ):
        record(name, "pending", detail)
    return {"ready": all(check["status"] == "passed" for check in checks), "checks": checks}


def exit_code(result):
    if any(check["status"] == "failed" for check in result["checks"]):
        return 1
    return 0 if result["ready"] else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Print the snapshot as JSON")
    args = parser.parse_args()
    result = collect(Path.home())
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        for check in result["checks"]:
            print(f"{check['status'].upper():7} {check['name']}: {check['detail']}")
        print("Manual/runtime evidence remains separate; follow docs/setup/macos.md.")
    return exit_code(result)


if __name__ == "__main__":
    raise SystemExit(main())
