"""Explicit machine preparation on disposable GitHub-hosted Windows x64 runners.

This command installs tools and may request legitimate installer elevation.
It does not run the build verifier or prove standard-user readiness.
"""

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provision", action="store_true", required=True)
    parser.parse_args()
    if os.name != "nt" or platform.machine().lower() not in ("amd64", "x86_64") or os.environ.get("PROCESSOR_ARCHITEW6432"):
        raise RuntimeError("Preparation requires native Windows x64 and Python")
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("--provision is restricted to disposable GitHub-hosted Windows x64 runners")
    mise = shutil.which("mise")
    if not mise:
        raise RuntimeError("Required preparation executable is not on PATH: mise")
    for application in (1, 2):
        print(f"Explicit build-environment preparation {application}/2", flush=True)
        subprocess.run([mise, "run", "windows-build"], cwd=REPO, check=True, timeout=10800)
    print("Preparation completed, not build verification. Run tests/smoke_windows_build_environment.py --verify-only "
          "separately in the prepared user's non-elevated terminal.", flush=True)


if __name__ == "__main__":
    main()
