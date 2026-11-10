#!/usr/bin/env bash
# Structural policy, event truth table, and workflow mutation tests.
set -euo pipefail
python3 - "$@" <<'PY'
import copy
import json
from pathlib import Path
import re
import subprocess
import sys
import os
import tempfile
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
light = "!cancelled() && (github.event_name != 'pull_request' || needs.changes.result != 'success' || needs.changes.outputs.docs_only != 'true')"
full = "!cancelled() && (github.event_name == 'push' || github.event_name == 'workflow_dispatch' || (github.event_name == 'pull_request' && contains(github.event.pull_request.labels.*.name, 'full-ci'))) && (github.event_name != 'pull_request' || needs.changes.result != 'success' || needs.changes.outputs.docs_only != 'true')"
docs = "!cancelled() && github.event_name == 'pull_request' && needs.changes.result == 'success' && needs.changes.outputs.docs_only == 'true'"
heavy = {"host-checks", "hosts", "build", "build-darwin", "vm-check-names", "vm-checks"}

def policy(w):
    triggers = w.get("on", w.get(True))
    assert triggers["push"]["branches"] == ["main"]
    assert "workflow_dispatch" in triggers
    assert set(triggers["pull_request"]["types"]) == {"opened", "synchronize", "reopened", "labeled"}
    jobs = w["jobs"]
    assert "build-linux" not in jobs
    assert "if" not in jobs["fmt"] and "needs" not in jobs["fmt"]
    assert jobs["changes"]["if"] == "github.event_name == 'pull_request'"
    for name in heavy | {"flake-check", "check-shard-names", "check-shards", "markdown-lint"}:
        j = jobs[name]
        assert j["if"] == (full if name in heavy else docs if name == "markdown-lint" else light), name
        needs = j["needs"]
        assert "changes" in ([needs] if isinstance(needs, str) else needs), name
    for consumer, producer, output, key in [
        ("build", "hosts", "targets", "target"),
        ("build-darwin", "hosts", "darwin_targets", "target"),
        ("check-shards", "check-shard-names", "names", "name"),
        ("vm-checks", "vm-check-names", "names", "name"),
    ]:
        assert producer in jobs[consumer]["needs"]
        assert jobs[consumer]["strategy"]["matrix"][key] == "${{ fromJSON(needs." + producer + ".outputs." + output + ") }}"
    for name in ["check-shard-names", "vm-check-names"]:
        script = "\n".join(s.get("run", "") for s in jobs[name]["steps"])
        assert 'if [ "$names" = "[]" ]; then' in script and "exit 1" in script
    shard_script = "\n".join(s.get("run", "") for s in jobs["check-shard-names"]["steps"])
    assert 'builtins.filter (n: builtins.match "light-.*" n != null)' in shard_script
    assert jobs["build-darwin"]["runs-on"] == "macos-15"
    # Catch future closure jobs as well as the named jobs above.
    for name, job in jobs.items():
        script = "\n".join(s.get("run", "") for s in job["steps"])
        if re.search(r"checkShards\.hosts|nixosConfigurations|darwinConfigurations|vmChecks", script):
            assert job.get("if") == full, name

policy(workflow)
# Every heavy gate must reject classifier failures too on an unlabelled PR.
def evaluate(condition, event, label, result, only_docs, action="synchronize", added=""):
    expression = condition.replace("!cancelled()", "True")
    for old, new in [
        ("contains(github.event.pull_request.labels.*.name, 'full-ci')", str(label)),
        ("github.event.action", repr(action)),
        ("github.event.label.name", repr(added)),
        ("github.event_name", repr(event)),
        ("needs.changes.result", repr(result)),
        ("needs.changes.outputs.docs_only", repr(only_docs)),
        ("&&", " and "), ("||", " or "),
    ]:
        expression = expression.replace(old, new)
    return eval(expression, {"__builtins__": {}}, {})

for event in ["push", "workflow_dispatch", "pull_request"]:
    for label in [False, True]:
        for result in ["success", "failure", "skipped"]:
            for only_docs in ["true", "false", ""]:
                skip = event == "pull_request" and result == "success" and only_docs == "true"
                for name, job in workflow["jobs"].items():
                    if name in heavy:
                        want = (event != "pull_request" or label) and not skip
                    elif name in {"flake-check", "check-shard-names", "check-shards"}:
                        want = not skip
                    elif name == "markdown-lint":
                        want = skip
                    else:
                        continue
                    assert evaluate(job["if"], event, label, result, only_docs) == want, name

for name in heavy:
    condition = workflow["jobs"][name]["if"]
    assert evaluate(condition, "pull_request", True, "success", "false", "labeled", "unrelated")
    assert not evaluate(condition, "pull_request", False, "success", "false", "labeled", "unrelated")
    assert evaluate(condition, "pull_request", True, "success", "false", "labeled", "full-ci")
    old_label_gate = full.replace(
        "contains(github.event.pull_request.labels.*.name, 'full-ci')",
        "contains(github.event.pull_request.labels.*.name, 'full-ci') && (github.event.action != 'labeled' || github.event.label.name == 'full-ci')",
    )
    for replacement in [light, "True", old_label_gate]:
        mutant = copy.deepcopy(workflow)
        mutant["jobs"][name]["if"] = replacement
        try:
            policy(mutant)
        except AssertionError:
            pass
        else:
            raise AssertionError("survived broken full-ci gate: " + name)
mutant = copy.deepcopy(workflow)
for step in mutant["jobs"]["check-shard-names"]["steps"]:
    if "run" in step:
        step["run"] = step["run"].replace('builtins.filter (n: builtins.match "light-.*" n != null) (builtins.attrNames s)', 'builtins.attrNames s')
try:
    policy(mutant)
except AssertionError:
    pass
else:
    raise AssertionError("survived hosts shard in PR matrix")

# Evaluate the actual matrix producer with independent host/check fixtures.
jobs = workflow["jobs"]
script = next(s["run"] for s in jobs["hosts"]["steps"] if s.get("id") == "list")
expr = re.search(r"lists=\$\(nix eval --impure --json --expr '(.*?)'\)", script, re.S)[1]
fixture = '{ nixosConfigurations = { north = {}; north-bootstrap = {}; }; darwinConfigurations = { mac = {}; mac-bootstrap = {}; }; checks.aarch64-darwin.sample = {}; }'
expr = expr.replace("builtins.getFlake (toString ./.)", fixture)
result = subprocess.run(["nix", "--extra-experimental-features", "nix-command", "eval", "--store", "dummy://", "--json", "--expr", expr], check=True, capture_output=True, text=True)
assert json.loads(result.stdout) == {"targets": ["north", "north-bootstrap"], "darwin_targets": ["darwinConfigurations.mac.system darwinConfigurations.mac-bootstrap.system", "checks.aarch64-darwin.sample"]}

# Execute the workflow build consumers with an argv recorder.
with tempfile.TemporaryDirectory() as tmp:
    Path(tmp, "checks.aarch64-darwin.expanded").touch()
    for name, target, expected in [
        ("build", "north-bootstrap", [".#nixosConfigurations.north-bootstrap.config.system.build.toplevel"]),
        ("build-darwin", "darwinConfigurations.mac.system darwinConfigurations.mac-bootstrap.system checks.aarch64-darwin.*",
         [".#darwinConfigurations.mac.system", ".#darwinConfigurations.mac-bootstrap.system", ".#checks.aarch64-darwin.*"]),
    ]:
        body = next(s["run"] for s in jobs[name]["steps"] if "nix build" in s.get("run", ""))
        record = Path(tmp, "args")
        env = dict(os.environ, TARGET=target, RECORD=str(record))
        recorder = 'nix() { printf "%s\\0" "$@" > "$RECORD"; }; export -f nix\n'
        subprocess.run(["bash", "-eu", "-c", recorder + body], env=env, cwd=tmp, check=True)
        args = record.read_bytes().decode().split("\0")[:-1]
        assert [a for a in args if a.startswith(".#")] == expected

print("check-workflow-docs-skip: all event, matrix, and mutation assertions passed")
PY
