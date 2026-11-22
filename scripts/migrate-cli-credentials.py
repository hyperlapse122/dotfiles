#!/usr/bin/env python3
"""Split or rejoin CLI credential ciphertext from the repository root."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

LEGACY = Path("secrets/tokens.yaml")
MANIFEST = Path("modules/shared/cli-credentials.json")
SOPS_CONFIG = Path(".sops.yaml")


class MigrationError(Exception):
    pass


def run(args, data=None, env=None):
    result = subprocess.run(
        args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
    )
    if result.returncode:
        raise MigrationError(f"{args[0]} failed during {args[1]}")
    return result.stdout


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise MigrationError("duplicate credential field or metadata key")
        obj[key] = value
    return obj


def parse(data):
    return json.loads(data, object_pairs_hook=unique_object)


def rule_recipients(path):
    rule = parse(run(
        ["yq", "-o=json",
         '[.creation_rules[] | . as $rule | select(strenv(SECRET_PATH) | '
         'test($rule.path_regex // ""))][0]', SOPS_CONFIG],
        env={**os.environ, "SECRET_PATH": str(path)},
    ))
    if not isinstance(rule, dict) or set(rule) != {"path_regex", "age"}:
        raise MigrationError(f"{path}: expected a creation rule with age recipients only")
    recipients = {item.strip() for item in rule["age"].split(",")}
    if not all(item.startswith("age1") for item in recipients):
        raise MigrationError(f"{path}: expected native age recipients")
    return recipients


def nixos_recipients():
    # Match host discovery in lib/hosts.nix: only Darwin hosts have host.nix.
    return {
        (Path("secrets/bootstrap") / host.name / "recipient.txt").read_text().strip()
        for host in Path("hosts").iterdir()
        if host.is_dir() and not (host / "host.nix").is_file()
    }


def decrypt(path, ciphertext, expected_recipients):
    document = parse(run(["yq", "-o=json", ".", "-"], ciphertext))
    metadata = document.pop("sops")
    if set(metadata) - {
        "age", "encrypted_suffix", "unencrypted_suffix", "encrypted_regex",
        "unencrypted_regex", "mac", "mac_only_encrypted", "version", "lastmodified",
    }:
        raise MigrationError(f"{path}: expected age-only SOPS metadata")
    if {key["recipient"] for key in metadata["age"]} != expected_recipients:
        raise MigrationError(f"{path}: ciphertext recipients differ from the creation rule")
    if not all(isinstance(value, str) and value.startswith("ENC[") for value in document.values()):
        raise MigrationError(f"{path}: expected every credential field to be encrypted")
    values = parse(run(
        ["sops", "decrypt", "--input-type", "yaml", "--output-type", "json",
         "--filename-override", str(path)], ciphertext
    ))
    if set(values) != set(document) or not all(isinstance(value, str) for value in values.values()):
        raise MigrationError(f"{path}: expected a flat document of string credentials")
    return values


def migrate(direction, output):
    if output.exists() or output.is_symlink():
        raise MigrationError("output directory already exists")
    manifest = parse(MANIFEST.read_bytes())
    groups = {
        spec["group"]: Path("secrets") / (spec["group"] + ".yaml")
        for spec in manifest.values()
    }
    required = {field for field, spec in manifest.items() if not spec.get("optional", False)}
    required_groups = {manifest[field]["group"] for field in required}
    restricted_groups = {spec["group"] for spec in manifest.values() if spec.get("darwin") is False}
    legacy_recipients = rule_recipients(LEGACY)
    permitted_nixos = legacy_recipients & nixos_recipients()
    recipients = {LEGACY: legacy_recipients}
    for group, path in groups.items():
        recipients[path] = rule_recipients(path)
        if group in restricted_groups:
            if not recipients[path] <= permitted_nixos:
                raise MigrationError(f"{path}: expected only recorded NixOS recipients")
        elif recipients[path] != legacy_recipients:
            raise MigrationError(f"{path}: creation rule recipients differ from {LEGACY}")

    merged = {}
    sources = {None: LEGACY} if direction == "forward" else groups
    for group, path in sources.items():
        if group is not None and group not in required_groups and not path.exists():
            continue
        values = decrypt(path, path.read_bytes(), recipients[path])
        if values.keys() - manifest.keys():
            raise MigrationError(f"{path}: unknown credential field; classify it before migrating")
        if group is not None and any(manifest[field]["group"] != group for field in values):
            raise MigrationError(f"{path}: a credential field is in the wrong group")
        merged.update(values)
    if not required <= merged.keys():
        raise MigrationError("required credential field is missing")

    if direction == "forward":
        targets = {}
        for group, path in groups.items():
            values = {field: value for field, value in merged.items() if manifest[field]["group"] == group}
            if values:
                targets[path] = values
    else:
        # Roll back shared credentials only. Restricted ciphertext stays in place.
        targets = {LEGACY: {
            field: value for field, value in merged.items()
            if manifest[field]["group"] not in restricted_groups
        }}
    encrypted = {}
    for path, values in targets.items():
        ciphertext = run(
            ["sops", "--config", str(SOPS_CONFIG), "encrypt", "--input-type", "json",
             "--output-type", "yaml", "--filename-override", str(path)],
            json.dumps(values).encode(),
        )
        if decrypt(path, ciphertext, recipients[path]) != values:
            raise MigrationError(f"{path}: encrypted round trip changed credential values")
        encrypted[path.name] = ciphertext

    # All writes contain verified ciphertext. A fresh directory keeps source
    # files and earlier migration output intact, including on a failed write.
    output.mkdir(mode=0o700)
    for name, ciphertext in encrypted.items():
        (output / name).write_bytes(ciphertext)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("direction", choices=("forward", "reverse"))
    parser.add_argument("output", type=Path, help="new directory for verified ciphertext")
    args = parser.parse_args()
    try:
        migrate(args.direction, args.output)
    except MigrationError as exc:
        sys.exit(f"CLI credential migration: {exc}")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Parsers and subprocesses can include secret material in diagnostics.
        sys.exit("CLI credential migration: invalid input or inaccessible path; check the repository root and output path")
    print(f"CLI credential migration: wrote {args.direction} ciphertext to {args.output}")


if __name__ == "__main__":
    main()
