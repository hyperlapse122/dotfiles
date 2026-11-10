"""Exercise the delivered CE worker with an offline ACP stream, never a peer.

The fixture supplies findings, not identity receipts. Only the shipped worker
owns normalization and the decision to publish an artifact.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


script = Path(sys.argv[1]).resolve() / "skills/ce-code-review/scripts/cross-model-adversarial-review.sh"
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    work = root / "repo"
    work.mkdir()
    # A deleted-file diff from a tree object needs neither commits nor an index.
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    blob = subprocess.check_output(["git", "hash-object", "-w", "--stdin"], cwd=work,
                                   input="offline review fixture\n", text=True).strip()
    base = subprocess.check_output(["git", "mktree"], cwd=work,
                                   input=f"100644 blob {blob}\tdeleted.txt\n", text=True).strip()
    binary = root / "bin"
    binary.mkdir()
    (binary / "python3").symlink_to(sys.executable)
    for name, body in {
        "node": "#!/bin/sh\nprintf '24.0.0\\n'\n",
        "codex": "#!/bin/sh\nexit 99\n",
        "npx": """#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['OMP_CE_CALL']).write_text(json.dumps(sys.argv[1:]))
if os.environ.get('OMP_CE_EMPTY'):
    sys.exit(0)
for message in [
    {'id': 7, 'method': 'session/prompt'},
    {'method': 'session/update', 'params': {'update': {
        'sessionUpdate': 'agent_message_chunk', 'content': {'text': json.dumps({
            'reviewer': 'offline fixture', 'findings': [],
            'residual_risks': ['offline transport only'], 'testing_gaps': ['no authenticated peer']})}}}},
    {'id': 7, 'result': {'stopReason': 'end_turn'}}]:
    print(json.dumps(message))
""",
    }.items():
        path = binary / name
        body = body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1)
        body = body.replace("#!/bin/sh", f"#!{shutil.which('sh')}", 1)
        path.write_text(body)
        path.chmod(0o755)

    def run(name, host="unknown", **overrides):
        destination = root / name
        destination.mkdir()
        (destination / "adversarial-review-constraints.md").write_text("none\n")
        called = destination / "transport.json"
        env = {"PATH": f"{binary}:{os.environ['PATH']}", "HOME": str(root),
               "CROSS_MODEL_HOST_HARNESS": "omp", "CROSS_MODEL_FIXED_ROUTE": "codex",
               "CROSS_MODEL_PEERS": "codex", "CROSS_MODEL_HARD_SECS": "15",
               "OMP_CE_CALL": str(called), "GIT_OPTIONAL_LOCKS": "0", **overrides}
        result = subprocess.run(["bash", str(script), host, "codex", base, str(destination)],
                                cwd=work, env=env, capture_output=True, text=True, timeout=25)
        assert result.returncode == 0, result.stderr
        artifact = destination / "adversarial-codex.json"
        return result, called, artifact

    result, called, artifact = run("automatic")
    assert "automatic cross-model review skipped" in result.stderr, result.stderr
    assert not called.exists() and not artifact.exists()

    result, called, artifact = run("explicit", CROSS_MODEL_EXPLICIT_UNKNOWN_HOST="1")
    assert called.exists(), result.stderr
    assert artifact.is_file(), result.stderr  # exit zero alone is never success
    value = json.loads(artifact.read_text())
    assert value["reviewer"] == "adversarial-codex"
    assert value["independence_verified"] is False, value
    assert value["model_actual"] == value["effort_actual"] == "unverified", value
    assert value["cross_model_route"] == "codex", value
    assert value["residual_risks"] == ["offline transport only"]
    assert value["testing_gaps"] == ["no authenticated peer"]
    argv = json.loads(called.read_text())
    assert "--approve-reads" in argv and "--non-interactive-permissions" in argv, argv
    assert argv[argv.index("--non-interactive-permissions") + 1] == "deny", argv
    assert "mode=read-only" in argv, argv

    for name, host, overrides, reason in [
        ("invalid-family", "glm", {}, "host serving family 'glm' invalid"),
        ("same-family", "codex", {}, "no different-provider peer reachable"),
        ("no-allowlist", "unknown", {"CROSS_MODEL_PEERS": ""}, "requires an allowlist"),
        ("excluded", "unknown", {"CROSS_MODEL_PEERS": "claude"}, "not in CROSS_MODEL_PEERS"),
        ("no-route", "unknown", {"CROSS_MODEL_FIXED_ROUTE": ""}, "requires one fixed candidate"),
        ("bad-model", "unknown", {"CROSS_MODEL_MODEL_OVERRIDE_TARGET": "codex",
                                   "CROSS_MODEL_MODEL_OVERRIDE": "glm-5.3"}, "not compatible"),
        ("wrong-harness", "unknown", {"CROSS_MODEL_HOST_HARNESS": "claude"}, "requires the OMP harness"),
        ("empty-output", "unknown", {"OMP_CE_EMPTY": "1"}, "acpx exited 0 before sending the prompt"),
    ]:
        result, called, artifact = run(name, host, CROSS_MODEL_EXPLICIT_UNKNOWN_HOST="1", **overrides)
        assert reason in result.stderr, (name, result.stderr)
        assert not artifact.exists(), (name, artifact)
        assert called.exists() == (name == "empty-output"), (name, result.stderr)
print("OMP CE explicit unknown-host worker passed offline; independence remains unverified")
