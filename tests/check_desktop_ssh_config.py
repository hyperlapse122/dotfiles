"""Inspect public source metadata and the files Home Manager/systemd materialize."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
import yaml


def sources(root):
    errors = []
    seen = set()
    rules = yaml.safe_load((root / ".sops.yaml").read_text())["creation_rules"]
    for directory in sorted((root / "hosts").iterdir()):
        if not directory.is_dir() or (directory / "host.nix").exists():
            continue
        relative = f"secrets/hosts/{directory.name}/ssh.yaml"
        try:
            recipient = (root / "secrets/bootstrap" / directory.name / "recipient.txt").read_text().strip()
            document = yaml.safe_load((root / relative).read_text())
            if set(document) != {"ssh_private_key", "sops"}:
                errors.append(f"{directory.name}: unexpected source fields")
            if not isinstance(document.get("ssh_private_key"), str) or not document["ssh_private_key"].startswith("ENC[AES256_GCM,"):
                errors.append(f"{directory.name}: missing SSH ciphertext")
            metadata = document.get("sops", {})
            if [item.get("recipient") for item in metadata.get("age", [])] != [recipient]:
                errors.append(f"{directory.name}: wrong recipient")
            if any(metadata.get(provider) for provider in ("pgp", "kms", "gcp_kms", "azure_kv", "hc_vault", "key_groups")):
                errors.append(f"{directory.name}: additional SOPS provider")
            matching = [rule for rule in rules if re.search(rule["path_regex"], relative)]
            if not matching or matching[0].get("age") != recipient:
                errors.append(f"{directory.name}: wrong creation-rule recipient")
            if matching and any(matching[0].get(provider) for provider in ("pgp", "kms", "gcp_kms", "azure_kv", "hc_vault", "key_groups")):
                errors.append(f"{directory.name}: additional creation-rule provider")
            public = (root / "secrets/hosts" / directory.name / "ssh.pub").read_bytes()
            key = serialization.load_ssh_public_key(public)
            if not isinstance(key, Ed25519PublicKey):
                errors.append(f"{directory.name}: public key is not Ed25519")
            canonical = key.public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
            if canonical in seen:
                errors.append(f"{directory.name}: duplicate public key")
            seen.add(canonical)
        except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
            errors.append(f"{directory.name}: missing or invalid source metadata ({type(error).__name__})")
    if not seen:
        errors.append("no headed SSH sources covered")
    return errors


def verify_ssh_activation(entry, config_path, require):
    require("linkGeneration" in entry.get("sshAfter", []),
            "sshConfig activation does not run after linkGeneration")
    activation = entry.get("sshActivation", "")
    script = 'set -euo pipefail\nrun() { "$@"; }\n' + activation
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        env = dict(os.environ, HOME=str(home))
        ssh_dir = home / ".ssh"
        ssh_config = ssh_dir / "config"
        unmanaged = ssh_dir / "config.unmanaged"

        res = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        require(res.returncode == 0, f"sshConfig activation failed on fresh HOME: {res.stderr.strip()}")
        require(ssh_dir.is_dir() and stat.S_IMODE(ssh_dir.stat().st_mode) == 0o700,
                "activation did not create ~/.ssh with mode 0700")
        require(ssh_config.is_file() and not ssh_config.is_symlink()
                and stat.S_IMODE(ssh_config.stat().st_mode) == 0o600
                and ssh_config.read_bytes() == config_path.read_bytes(),
                "activation did not install a 0600 regular ~/.ssh/config matching configFile")
        require(not unmanaged.exists(), "activation created ~/.ssh/config.unmanaged on fresh HOME")

        user_bytes = b"Host custom\n  User alice\n"
        ssh_config.write_bytes(user_bytes)
        res = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        require(res.returncode == 0, f"sshConfig activation failed on unmanaged config: {res.stderr.strip()}")
        require(unmanaged.is_file() and unmanaged.read_bytes() == user_bytes,
                "activation did not back up unmanaged ~/.ssh/config to ~/.ssh/config.unmanaged")
        require(ssh_config.is_file() and not ssh_config.is_symlink()
                and stat.S_IMODE(ssh_config.stat().st_mode) == 0o600
                and ssh_config.read_bytes() == config_path.read_bytes(),
                "activation did not replace unmanaged ~/.ssh/config with managed config")

        res = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        require(res.returncode == 0, f"sshConfig activation failed on managed re-run: {res.stderr.strip()}")
        require(unmanaged.read_bytes() == user_bytes
                and sorted(p.name for p in ssh_dir.iterdir()) == ["config", "config.unmanaged"],
                "re-running activation on managed ~/.ssh/config clobbered or duplicated ~/.ssh/config.unmanaged")
        unmanaged.unlink()
        res = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        require(res.returncode == 0 and not unmanaged.exists()
                and ssh_config.read_bytes() == config_path.read_bytes(),
                "re-running activation on managed ~/.ssh/config created ~/.ssh/config.unmanaged")

def configuration(entry, root):
    errors = []
    def require(condition, message):
        if not condition:
            errors.append(f"{entry['name']}: {message}")
    files = Path(entry["files"]) if entry["files"] else None
    config_path = Path(entry["sshConfig"]) if entry["sshConfig"] else Path("/absent-ssh-config")
    require(config_path.is_file(), "missing materialized SSH configuration")
    # A store link would be owned by nobody inside a user-namespace sandbox,
    # where ssh rejects it, so activation installs a user-owned copy instead.
    linked = files / ".ssh/config" if files else Path("/absent-home-files")
    require(not linked.exists() and not linked.is_symlink(), "~/.ssh/config is linked into the store")
    if config_path.is_file():
        verify_ssh_activation(entry, config_path, require)
    else:
        require(False, "cannot verify sshConfig activation without config_path")
    text = config_path.read_text() if config_path.is_file() else ""
    if entry["kind"] == "nixos":
        fallback_config = files / ".config/1Password/ssh/agent.toml" if files else Path("/absent-fallback-config")
        require(fallback_config.is_file() and fallback_config.read_text() == entry["fallbackConfig"], "1Password key selection changed")
    headed = entry["kind"] == "nixos" and not entry["bootstrap"]
    agent_path = files / ".config/systemd/user/desktop-ssh-agent.service" if files else Path("/absent-agent")
    json_path = files / ".config/desktop-ssh/config.json" if files else Path("/absent-config")
    system_path = Path(entry["systemUnit"]) / "desktop-ssh-provision.service" if entry["systemUnit"] else Path("/absent-system-unit")
    if not headed:
        require(not agent_path.exists() and not agent_path.is_symlink(), "bootstrap/non-NixOS session unit leaked")
        require(not json_path.exists(), "bootstrap/non-NixOS desktop config leaked")
        require(not system_path.exists() and not system_path.is_symlink(), "bootstrap provisioning unit leaked")
        if entry["kind"] == "nixos":
            require("IdentityAgent ~/.1password/agent.sock" in text, "bootstrap lost legacy agent")
        else:
            require(f"IdentityFile {entry['legacyKey']}" in text, "non-NixOS SSH path changed")
        return errors
    require("IdentityAgent /run/user/%i/desktop-ssh/agent.sock" in text, "incorrect primary IdentityAgent")
    require("IdentityFile /nix/store/" in text, "missing declared public identity")
    require(json_path.is_file(), "missing desktop configuration")
    if json_path.is_file():
        try:
            config = json.loads(json_path.read_text())
            effective = subprocess.run(
                ["ssh", "-G", "-F", str(config_path), "desktop-ssh-check.invalid"],
                check=True, capture_output=True, text=True, timeout=5).stdout
            options = [line.split(None, 1) for line in effective.splitlines() if " " in line]
            require([value for name, value in options if name == "identityfile"] == [config.get("public_key")],
                    "SSH public identity differs from agent metadata")
            require([value for name, value in options if name == "identityagent"] ==
                    [f"/run/user/{os.getuid()}/desktop-ssh/agent.sock"], "incorrect effective primary IdentityAgent")
            require(config.get("key_file") == entry["home"] + "/.ssh/id_ed25519_nix_config", "incorrect working key")
            require(config.get("fallback_socket") == entry["home"] + "/.1password/agent.sock", "incorrect fallback socket")
            require(Path(config.get("public_key", "")).is_file(), "missing public metadata")
            actual = serialization.load_ssh_public_key(Path(config["public_key"]).read_bytes())
            declared = serialization.load_ssh_public_key(
                (root / "secrets/hosts" / entry["hostName"] / "ssh.pub").read_bytes())
            require(isinstance(actual, Ed25519PublicKey) and
                    actual.public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH) ==
                    declared.public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH),
                    "agent public identity differs from this host's declared key")
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
            require(False, "invalid desktop configuration")
            config = {}
    else:
        config = {}
    for tool in ("ssh", "scp", "sftp"):
        executable = Path(entry["path"]) / "bin" / tool if entry["path"] else Path("/absent-tool")
        require(executable.is_file() and executable.resolve() == Path(entry["package"]) / "bin/desktop-ssh", f"{tool} does not select packaged launcher")
    require(agent_path.is_file(), "missing or masked primary service")
    if agent_path.is_file():
        unit = agent_path.read_text()
        for fragment in ("BindsTo=graphical-session.target", "PartOf=graphical-session.target", "After=graphical-session.target", "RuntimeDirectory=desktop-ssh", "RuntimeDirectoryMode=0700", "LimitCORE=0", "KillMode=control-group", "ExecCondition=", "ExecStopPost="):
            require(fragment in unit, "primary unit missing " + fragment)
        require(re.search(r"^ExecStart=.*?/bin/desktop-ssh[ '\"]+agent(?: |['\"])", unit, re.M), "primary unit does not run packaged agent")
        wanted = agent_path.parent / "graphical-session.target.wants/desktop-ssh-agent.service"
        require(wanted.is_symlink() and wanted.resolve() == agent_path.resolve(), "primary service missing graphical target installation")
    require(not (agent_path.parent / "desktop-ssh-agent.socket").exists(), "unexpected socket activation")
    require(system_path.is_file(), "missing or masked provisioning service")
    if system_path.is_file():
        unit = system_path.read_text()
        for fragment in ("User=" + entry["user"], "LoadCredential=", "%d/source", "LimitCORE=0"):
            require(fragment in unit, "provisioning unit missing " + fragment)
        require(re.search(r"^ExecStart=.*?/bin/desktop-ssh[ '\"]+provision(?: |['\"])", unit, re.M), "provisioning unit does not run packaged provisioner")
        start = re.search(r"^ExecStart=(.+)$", unit, re.M)
        try:
            arguments = shlex.split(start[1]) if start else []
        except ValueError:
            arguments = []
        for option, field in (("--public-key", "public_key"), ("--key-file", "key_file")):
            index = arguments.index(option) if arguments.count(option) == 1 else len(arguments)
            require(index + 1 < len(arguments) and arguments[index + 1] == config.get(field),
                    "provisioning " + option + " differs from agent metadata")
        installed_targets = list(system_path.parent.glob("*.wants/desktop-ssh-provision.service"))
        installed_targets += list(system_path.parent.glob("*.requires/desktop-ssh-provision.service"))
        require(not installed_targets, "provisioning attempts boot-time wallet access through target installation")
    return errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--entries", type=Path)
    args = parser.parse_args()
    failures = sources(args.root)
    if args.entries is not None:
        for entry in json.loads(args.entries.read_text()):
            failures.extend(configuration(entry, args.root))
    if failures:
        print("\n".join("desktop-ssh: " + failure for failure in failures), file=sys.stderr)
        sys.exit(1)
