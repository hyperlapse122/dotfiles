"""Exercise managed T3 launchers and omp ACP settings without applying personal state.

--install-desktop provisions an official desktop release on disposable CI only.
It does not test WinGet acquisition; the normal Windows apply uses WinGet.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from smoke_personal_apps import executable, run, temporary_destination


REPO = Path(__file__).resolve().parents[1]


def provision_desktop(target, root, env):
    if not (env.get("GITHUB_ACTIONS") == "true" and env.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise RuntimeError("Desktop provisioning is restricted to disposable GitHub-hosted runners")
    if target == "darwin-arm64":
        run([executable("brew"), "install", "--cask", "t3-code"], env=env, cwd=root)
        return
    release = json.loads(run([executable("gh"), "api", "repos/pingdotgg/t3code/releases/latest"], env=env, cwd=root))
    if release.get("draft") or release.get("prerelease"):
        raise RuntimeError("Expected a stable T3 desktop release")
    arch = target.split("-", 1)[1]
    version = release["tag_name"].removeprefix("v")
    asset_name = f"T3-Code-{version}-{arch}.deb" if target.startswith("linux-") else f"T3-Code-{version}-{'x64' if arch == 'amd64' else 'arm64'}.exe"
    matches = [asset for asset in release["assets"] if asset["name"] == asset_name]
    if len(matches) != 1 or not matches[0].get("digest", "").startswith("sha256:"):
        raise RuntimeError(f"No uniquely checksummed T3 desktop asset: {asset_name}")
    asset = root / asset_name
    run([executable("gh"), "release", "download", release["tag_name"], "--repo", "pingdotgg/t3code", "--pattern", asset_name, "--dir", str(root)], env=env, cwd=root)
    with asset.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != matches[0]["digest"][7:]:
        raise RuntimeError("T3 desktop checksum mismatch")
    if target.startswith("windows-"):
        run([str(asset), "/S"], env=env, cwd=root)
    else:
        run([executable("sudo"), "apt-get", "update"], env=env, cwd=root)
        run([executable("sudo"), "apt-get", "install", "-y", str(asset)], env=env, cwd=root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-desktop", action="store_true")
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    real_home = Path.home()
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / name for name in ("user home", "source", "unrelated cwd"))
        for directory in (home, source, outside):
            directory.mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates", "private_dot_t3", "dot_local"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        shutil.copy2(REPO / "home/.chezmoiignore", source / ".chezmoiignore")
        config = root / "chezmoi.toml"
        config.write_text("", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "ZDOTDIR": str(home),
            "APPDATA": str(root / "appdata"),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "T3CODE_HOME": str(home / ".t3"),
        })
        # Keep native app-install discovery (LOCALAPPDATA/Applications) separate
        # from the isolated T3/omp runtime state; no registry action is copied.
        command = [chezmoi, "--source", str(source), "--destination", str(home), "--config", str(config),
                   "--cache", str(root / "cache"), "--persistent-state", str(root / "state.boltdb"), "--no-tty"]
        target = run(command + ["execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}"], env=env, cwd=outside)
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in {"windows-amd64", "windows-arm64", "linux-amd64", "linux-arm64", "darwin-arm64"}:
            raise RuntimeError(f"Unsupported T3 smoke target: {target}")
        if args.install_desktop:
            provision_desktop(target, root, os.environ.copy())
        binary_name = "omp.exe" if os.name == "nt" else "omp"
        existing_omp = real_home / ".local/bin" / binary_name
        if existing_omp.is_file():
            destination = home / ".local/bin" / binary_name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(existing_omp, destination)
        else:
            external = source / ".chezmoiexternals/personal-apps.toml.tmpl"
            external.parent.mkdir()
            shutil.copy2(REPO / "home/.chezmoiexternals/personal-apps.toml.tmpl", external)
            declaration = source / ".chezmoidata/personal-apps.json"
            data = json.loads(declaration.read_text(encoding="utf-8"))
            data["personalApps"] = {"omp": data["personalApps"]["omp"]}
            declaration.write_text(json.dumps(data), encoding="utf-8")
        settings = home / ".t3/userdata/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"idleCompaction": "onReturn", "providerInstances": {
            "smoke-unrelated": {"driver": "codex", "enabled": False, "displayName": "Unrelated smoke provider", "config": {}}
        }}), encoding="utf-8")
        run(command + ["apply", "--force", "--exclude=scripts"], env=env, cwd=outside)
        first = json.loads(settings.read_text(encoding="utf-8"))
        if first["providerInstances"]["smoke-unrelated"]["displayName"] != "Unrelated smoke provider" or first["idleCompaction"] != "onReturn":
            raise RuntimeError("Provider reconciliation changed unrelated settings")
        launcher = home / ".local/bin" / ("t3.cmd" if os.name == "nt" else "t3")
        if (home / ".t3/bin" / launcher.name).exists():
            raise RuntimeError("Smoke must not depend on an app-generated CLI shim")
        child = env.copy()
        child["PATH"] = str(launcher.parent) + os.pathsep + env.get("PATH", "")
        if os.name == "nt":
            version = run([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", "t3 --version"], env=child, cwd=outside)
        else:
            version = run(["/bin/sh", "-c", "command -v t3; t3 --version"], env=child, cwd=outside)
        if "t3 v" not in version:
            raise RuntimeError(f"Unexpected bundled CLI version: {version}")
        provider = first["providerInstances"]["omp"]
        request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "dotfiles-smoke", "version": "1"}
        }}
        response = subprocess.run([provider["config"]["commandPath"], *provider["config"]["commandArgs"]],
                                  input=json.dumps(request) + "\n", env=child, cwd=outside,
                                  capture_output=True, text=True, encoding="utf-8", timeout=60)
        messages = [json.loads(line) for line in response.stdout.splitlines() if line.startswith("{")]
        initialized = next((message.get("result") for message in messages if message.get("id") == 1), None)
        if response.returncode or not initialized or initialized.get("agentInfo", {}).get("name") != "omp":
            raise RuntimeError(f"ACP initialization failed: {response.stdout}\n{response.stderr}")
        run(command + ["apply", "--force", "--exclude=scripts"], env=env, cwd=outside)
        if json.loads(settings.read_text(encoding="utf-8")) != first:
            raise RuntimeError("Repeated provider reconciliation did not converge")
        print(f"Native {target}: {version}; managed omp ACP initialize succeeded; unrelated settings and reapply preserved")


if __name__ == "__main__":
    main()
