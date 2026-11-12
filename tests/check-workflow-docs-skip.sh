#!/usr/bin/env bash
# Structural policy, event truth table, concurrency groups, and workflow
# mutation tests.
set -euo pipefail
python3 - "$@" <<'PY'
import copy
import itertools
import json
from pathlib import Path
import re
import subprocess
import sys
import os
import tempfile
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text())
heavy = {"host-checks", "hosts", "build", "build-darwin", "vm-check-names", "vm-checks"}
light = {"flake-check", "check-shard-names", "check-shards"}

def policy(w):
    triggers = w.get("on", w.get(True))
    assert triggers["push"]["branches"] == ["main"]
    assert "workflow_dispatch" in triggers
    assert set(triggers["pull_request"]["types"]) == {"opened", "synchronize", "reopened", "labeled"}
    jobs = w["jobs"]
    assert "build-linux" not in jobs
    assert "needs" not in jobs["fmt"]
    for name in heavy | light | {"markdown-lint"}:
        needs = jobs[name]["needs"]
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
    assert jobs["build-darwin"]["runs-on"] == "macos-26"
    # A future closure job must join the heavy set so the truth table gates it.
    for name, job in jobs.items():
        script = "\n".join(s.get("run", "") for s in job["steps"])
        if re.search(r"checkShards\.hosts|nixosConfigurations|darwinConfigurations|vmChecks", script):
            assert name in heavy, name

def evaluate(condition, ctx):
    """Evaluate a GitHub Actions expression over a flat context."""
    expression = condition.replace("!cancelled()", "True")
    expression = expression.replace(
        "contains(github.event.pull_request.labels.*.name, 'full-ci')", repr(ctx["has_label"]))
    for name in ["github.event.label.name", "github.event.action", "github.event_name",
                 "github.workflow", "github.ref", "github.run_id",
                 "needs.changes.result", "needs.changes.outputs.docs_only"]:
        expression = expression.replace(name, repr(ctx[name]))
    expression = expression.replace("&&", " and ").replace("||", " or ")
    assert "!" not in expression.replace("!=", ""), expression
    scope = {"format": lambda template, *args: template.format(*args)}
    return eval(expression, {"__builtins__": {}}, scope)

def interpolate(template, ctx):
    return re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(evaluate(m[1].strip(), ctx)), template)

def context(event, action="", added="", has_label=False, result="skipped", docs="", ref="refs/pull/7/merge", run_id="1"):
    return {
        "github.event_name": event, "github.event.action": action, "github.event.label.name": added,
        "has_label": has_label, "needs.changes.result": result, "needs.changes.outputs.docs_only": docs,
        "github.workflow": "Nix", "github.ref": ref, "github.run_id": run_id,
    }

def runs(job, ctx):
    return evaluate(job["if"], ctx) if "if" in job else True

def behavior(w):
    jobs = w["jobs"]
    cases = [("push", ""), ("workflow_dispatch", "")] + [
        ("pull_request", a) for a in ["opened", "synchronize", "reopened", "labeled"]]
    for (event, action), added, has_label, result, docs in itertools.product(
            cases, ["full-ci", "bug"], [False, True], ["success", "failure", "skipped"], ["true", "false", ""]):
        if action != "labeled" and added != "full-ci":
            continue
        if action == "labeled" and added == "full-ci" and not has_label:
            continue
        ctx = context(event, action, added if action == "labeled" else "", has_label, result, docs)
        pr = event == "pull_request"
        label_event = pr and action == "labeled"
        docs_skip = pr and result == "success" and docs == "true"
        closure = (not pr or (label_event and added == "full-ci")
                   or (action in {"synchronize", "reopened"} and has_label))
        want = {"changes": pr and (not label_event or added == "full-ci"),
                "fmt": not label_event,
                "markdown-lint": not label_event and docs_skip}
        want.update({name: not label_event and not docs_skip for name in light})
        want.update({name: closure and not docs_skip for name in heavy})
        assert set(jobs) == set(want), sorted(set(jobs) ^ set(want))
        for name, expected in want.items():
            assert runs(jobs[name], ctx) == expected, (name, event, action, added, has_label, result, docs)

    concurrency = w["concurrency"]
    assert concurrency["cancel-in-progress"] is True
    group = lambda **kw: interpolate(concurrency["group"], context(**kw))
    pr_groups = {action: group(event="pull_request", action=action) for action in ["opened", "synchronize", "reopened"]}
    # A push replaces any earlier non-label run on the ref.
    assert len(set(pr_groups.values())) == 1, pr_groups
    assert group(event="pull_request", action="synchronize", run_id="1") == group(event="pull_request", action="synchronize", run_id="2")
    # A label run neither cancels nor is cancelled by any other run.
    labeled = [group(event="pull_request", action="labeled", added=a, run_id=r) for a, r in [("full-ci", "1"), ("full-ci", "2"), ("bug", "3")]]
    assert len(set(labeled)) == 3, labeled
    assert not set(labeled) & set(pr_groups.values()), labeled
    assert group(event="push", ref="refs/heads/main") == "Nix-refs/heads/main"
    assert group(event="push", ref="refs/heads/main", run_id="9") == group(event="workflow_dispatch", ref="refs/heads/main")

policy(workflow)
behavior(workflow)

def mutate(edit):
    mutant = copy.deepcopy(workflow)
    edit(mutant)
    assert mutant != workflow, "mutation changed nothing"
    return mutant

def replace_in(names, old, new):
    def edit(w):
        for name in names:
            assert old in w["jobs"][name]["if"], (name, old)
            w["jobs"][name]["if"] = w["jobs"][name]["if"].replace(old, new)
    return edit

def set_key(path, value):
    def edit(w):
        node = w
        for key in path[:-1]:
            node = node[key]
        if value is None:
            del node[path[-1]]
        else:
            node[path[-1]] = value
    return edit

closure_actions = "(github.event.action == 'synchronize' || github.event.action == 'reopened')"
label_gate = "(github.event.action == 'labeled' && github.event.label.name == 'full-ci')"
mutants = {
    "group without run id": set_key(["concurrency", "group"], "${{ github.workflow }}-${{ github.ref }}"),
    "group without action condition": set_key(["concurrency", "group"], "${{ github.workflow }}-${{ github.ref }}-labeled-${{ github.run_id }}"),
    "no cancel-in-progress": set_key(["concurrency", "cancel-in-progress"], False),
    "closure jobs on opened": replace_in(heavy, closure_actions, "github.event.action != 'labeled'"),
    "closure jobs on any label": replace_in(heavy, label_gate, "github.event.action == 'labeled'"),
    "light jobs on label runs": replace_in(light, "github.event.action != 'labeled' && ", ""),
    "markdown-lint on label runs": replace_in(["markdown-lint"], "github.event.action != 'labeled' && ", ""),
    "fmt on label runs": set_key(["jobs", "fmt", "if"], None),
    "changes on every label": set_key(["jobs", "changes", "if"], "github.event_name == 'pull_request'"),
}
for name in heavy:
    mutants["unlabelled closure: " + name] = replace_in([name], label_gate, "github.event_name == 'pull_request'")
for label, edit in mutants.items():
    try:
        behavior(mutate(edit))
    except AssertionError:
        pass
    else:
        raise AssertionError("survived mutation: " + label)

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

print("check-workflow-docs-skip: all event, concurrency, matrix, and mutation assertions passed")
PY
