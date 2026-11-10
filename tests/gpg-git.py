"""Exercise Git's signing adapter with an isolated card/agent boundary."""

import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time


script = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    fake = root / "gpg"
    fake.write_text(
        f"#!{sys.executable}\n" + r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["CARD_FIXTURE"])
args = sys.argv[1:]
payload = sys.stdin.buffer.read()
with (root / "calls").open("a") as log:
    log.write(json.dumps([args, payload.hex()]) + "\n")
mode = os.environ["CARD_MODE"]
if "--card-status" in args:
    print("private card metadata")
    print("private card diagnostic", file=sys.stderr)
    if mode == "hang":
        time.sleep(60)
    if mode == "refresh-fails":
        sys.exit(1)
    (root / "ready").touch()
    sys.exit(0)
if "-bsau" in args:
    if mode == "cold" and not (root / "ready").exists():
        print("[GNUPG:] INV_SGNR 9 fixture-key", file=sys.stderr)
        print("gpg: signing failed: No secret key", file=sys.stderr)
        sys.exit(2)
    if mode == "bad-pin":
        print("gpg: signing failed: Bad PIN", file=sys.stderr)
        sys.exit(2)
    sys.stdout.buffer.write(b"signature:" + payload)
    print("[GNUPG:] SIG_CREATED D", file=sys.stderr)
    sys.exit(0)
sys.stdout.buffer.write(payload)
print("verification diagnostic", file=sys.stderr)
sys.exit(7)
'''
    )
    fake.chmod(0o755)
    environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", CARD_FIXTURE=str(root))
    payload = b"commit payload\x00\xff\n"
    signing = ["--status-fd=2", "-bsau", "fixture-key"]
    for mode in ("cold", "refresh-fails", "hang", "bad-pin", "verify"):
        (root / "ready").unlink(missing_ok=True)
        (root / "calls").unlink(missing_ok=True)
        args = ["--status-fd=1", "--verify", "signature", "-"] if mode == "verify" else signing
        started = time.monotonic()
        result = subprocess.run(
            [sys.executable, script, *args], input=payload, capture_output=True,
            env=dict(environment, CARD_MODE=mode), timeout=20,
        )
        elapsed = time.monotonic() - started
        calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
        signing_calls = [call for call in calls if "-bsau" in call[0]]
        if mode == "verify":
            assert calls == [[args, payload.hex()]], "verification must not touch the card"
            assert (result.returncode, result.stdout, result.stderr) == (
                7, payload, b"verification diagnostic\n"
            ), "verification streams and exit status must pass through"
        else:
            assert calls[0] == [["--batch", "--card-status"], ""], "refresh must precede signing without consuming its stdin"
            assert signing_calls == [[signing, payload.hex()]], "sign exactly once with unchanged argv and stdin"
            if mode == "bad-pin":
                assert result.returncode == 2 and result.stdout == b""
                assert result.stderr == b"gpg: signing failed: Bad PIN\n", "preserve PIN failure without retry"
            else:
                assert result.returncode == 0, f"{mode}: {result.stderr!r}"
                assert result.stdout == b"signature:" + payload
                assert result.stderr == b"[GNUPG:] SIG_CREATED D\n", "refresh metadata must not enter Git's streams"
            if mode == "hang":
                assert 9 <= elapsed < 15, "refresh must have a bounded ten-second wait"
        print(f"gpg-git: {mode} passed")

    for name in ("SIGPIPE", "SIGXFSZ"):
        fake.write_text(f"#!/bin/sh\nkill -{int(getattr(signal, name))} $$\nexit 99\n")
        result = subprocess.run(
            [sys.executable, script, "--version"],
            capture_output=True, env=environment, timeout=5,
        )
        assert result.returncode == -getattr(signal, name), f"GPG must retain default {name} behavior"
        print(f"gpg-git: {name} passed")
