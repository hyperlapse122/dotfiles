"""Exercise the installed guide's read commands against local package versions."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def write_package(directory, metadata):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "package.json").write_text(json.dumps(metadata))


def project(directory, version, *, visible=True, installed=True):
    package = "@example/widget"
    write_package(directory, {
        "name": "consumer", "version": "1.0.0", "dependencies": {package: version},
        "intent": {"skills": [package] if visible else []},
    })
    if installed:
        dependency = directory / "node_modules" / package
        write_package(dependency, {
            "name": package, "version": version, "repository": "github:example/widget",
        })
        entry = dependency / "skills" / "setup" / "SKILL.md"
        entry.parent.mkdir(parents=True)
        entry.write_text(
            "---\nname: setup\ndescription: Configure a local widget.\n---\n\n"
            f"# Setup\n\nWidget version {version}.\n"
        )
    return directory


def snapshot(directory):
    return {p.relative_to(directory): p.read_bytes() for p in directory.rglob("*") if p.is_file()}


guide = Path(sys.argv[1]).read_text()
listing, loading, locating = re.findall(r"^```sh\n(.*?)\n```$", guide, re.M | re.S)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    env = {**os.environ, "HOME": temp, "package": "@example/widget", "use": "@example/widget#setup"}

    def run(command, cwd, *, check=True):
        return subprocess.run(["bash", "-euo", "pipefail", "-c", command], cwd=cwd,
                              env=env, capture_output=True, text=True, check=check)

    for version in ("1.0.0", "2.0.0"):
        cwd = project(root / version, version)
        before = snapshot(cwd)
        assert run(listing, cwd).stdout.split("\t")[:2] == [env["use"], version]
        assert f"Widget version {version}." in run(loading, cwd).stdout
        assert (cwd / run(locating, cwd).stdout.strip()).resolve() == (
            cwd / "node_modules/@example/widget/skills/setup/SKILL.md").resolve()
        assert snapshot(cwd) == before

    for condition in ("hidden", "missing"):
        cwd = project(root / condition, "1.0.0", visible=condition != "hidden",
                      installed=condition != "missing")
        before = snapshot(cwd)
        assert not run(listing, cwd).stdout.strip()
        assert run(loading, cwd, check=False).returncode != 0
        assert snapshot(cwd) == before
