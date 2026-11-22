"""Round-trip the fake legacy credentials through the maintenance CLI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

TOOL, MANIFEST, FIXTURE = (Path(arg).resolve() for arg in sys.argv[1:])


def run(*args, data=None):
    result = subprocess.run(
        args, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode:
        raise SystemExit(f"{Path(args[0]).name} failed in the fake migration test")
    return result.stdout


def decrypt(file):
    return json.loads(run("sops", "decrypt", "--output-type", "json", str(file)))


def encrypt_legacy(data, path, recipients):
    path.write_bytes(run(
        "sops", "encrypt", "--age", recipients, "--input-type", "json",
        "--output-type", "yaml", "--filename-override", str(path), data=data,
    ))


def migrate(direction, output):
    return subprocess.run(
        [sys.executable, TOOL, direction, output],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def expect_rejection(direction, reason):
    result = migrate(direction, "rejected")
    assert result.returncode != 0 and reason in result.stderr
    assert b"FAKE-CANARY" not in result.stdout + result.stderr
    assert not Path("rejected").exists()


with tempfile.TemporaryDirectory() as directory:
    os.chdir(directory)
    os.environ["HOME"] = directory
    os.environ["XDG_CONFIG_HOME"] = directory
    for name in list(os.environ):
        if name.startswith("SOPS_"):
            del os.environ[name]
    os.environ["SOPS_AGE_KEY_FILE"] = str(FIXTURE / "key.txt")
    recipient = (FIXTURE / "recipient.txt").read_text().strip()
    other = run("age-keygen", "-y", FIXTURE / "other-key.txt").decode().strip()
    secrets = Path("secrets")
    secrets.mkdir()
    manifest = Path("modules/shared/cli-credentials.json")
    manifest.parent.mkdir(parents=True)
    shutil.copyfile(MANIFEST, manifest)
    legacy = secrets / "tokens.yaml"
    expected = decrypt(FIXTURE / "tokens.yaml")
    recipients = f"{recipient},{other}"
    encrypt_legacy(json.dumps(expected).encode(), legacy, recipients)

    # The expected split is independent of the manifest used by the tool.
    git_fields = {"github_token", "gitlab_token", "jpi_token"}
    git = "git-hosting.yaml"
    services = "provider-services.yaml"

    def rules(service_recipients):
        Path(".sops.yaml").write_text(
            "creation_rules:\n"
            + "".join(
                f"  - path_regex: ^secrets/{name.replace('.', '[.]')}$\n"
                f"    age: {age}\n"
                for name, age in (
                    ("tokens.yaml", recipients),
                    (git, recipients),
                    (services, service_recipients),
                )
            )
        )

    rules(recipient)
    expect_rejection("forward", b"recipients differ")
    rules(recipients)
    assert migrate("forward", "split").returncode == 0, "forward migration failed"
    split = Path("split")
    assert set(p.name for p in split.iterdir()) == {git, services}
    assert decrypt(split / git) == {k: v for k, v in expected.items() if k in git_fields}
    assert decrypt(split / services) == {
        k: v for k, v in expected.items() if k not in git_fields
    }

    for name in (git, services):
        shutil.copyfile(split / name, secrets / name)
    original = legacy.read_bytes()
    rotated = "FAKE-CANARY rotated with a newline\n  and a space "
    run("sops", "set", "--value-stdin", secrets / services, '["openai_api_key"]',
        data=json.dumps(rotated).encode())
    expected["openai_api_key"] = rotated
    assert migrate("reverse", "merged").returncode == 0, "reverse migration failed"
    assert decrypt(Path("merged/tokens.yaml")) == expected
    assert legacy.read_bytes() == original

    run("sops", "set", "--value-stdin", secrets / services, '["unknown_field"]',
        data=json.dumps("FAKE-CANARY unknown").encode())
    expect_rejection("reverse", b"unknown credential field")
    assert migrate("forward", "split").returncode != 0
    assert decrypt(split / git) == {k: v for k, v in expected.items() if k in git_fields}

    encrypt_legacy(json.dumps(dict(expected, unknown_field="FAKE-CANARY")).encode(),
                   legacy, recipients)
    expect_rejection("forward", b"unknown credential field")
    duplicate = json.dumps(expected)[:-1] + ', "github_token": "FAKE-CANARY"}'
    encrypt_legacy(duplicate.encode(), legacy, recipients)
    expect_rejection("forward", b"duplicate credential field")

print("CLI credential migration: exact split and rotated rollback passed")
