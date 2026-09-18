#!/usr/bin/env bash
set -euo pipefail

# Static checks of the workflows that carry the compound-engineering overlay
# flow. It parses them as YAML and asserts the wiring that no test run can
# exercise before the owner prerequisites exist. Needs python3 with PyYAML, like
# .ci/test-ci-wiring.sh.
#
# USAGE  check-ce-overlay-wiring.sh [<repository root>]
#
# LOCK WORKFLOW (.github/workflows/refresh-release-lock.yml)
#   - every job has a timeout, and the workflow token holds exactly contents:
#     write, actions: write, pull-requests: write, and issues: read
#   - step order: resolve, install chezmoi, hold, digest check, commit, push,
#     dispatch decision, unresolved-source failure
#   - the dispatch decision runs only when the push succeeded or nothing was
#     committed, only for a rebase candidate, only on the default branch, names
#     that branch as its ref, never runs after a failed commit or push, and
#     warns rather than fails
#   - every checkout sets persist-credentials: false
#   - the App token is minted once, after the commit, and is read only by the
#     push step's environment; the private key is read only by the mint step
#   - the workflow never creates or merges a pull request
#   - every action except the two that predate this flow is pinned to a full
#     commit SHA with its release tag in a trailing comment
# EVERY WORKFLOW
#   - a job that calls the hold script, the upstream gate, or an offline overlay
#     test installs chezmoi in an earlier step, because the gate renders the
#     roster's authoring effort

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=${1:-$repo_root}

wiring_python=''
for candidate in /usr/bin/python3 python3; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    wiring_python=$candidate
    break
  fi
done
if [[ -z $wiring_python ]]; then
  printf 'check-ce-overlay-wiring: no python3 with PyYAML found; install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)\n' >&2
  exit 1
fi

"$wiring_python" - "$root" <<'PYTHON'
import json
import pathlib
import re
import sys

import yaml

LOCK_WORKFLOW = "refresh-release-lock.yml"
LOCK_PERMISSIONS = {
    "contents": "write",
    "actions": "write",
    "pull-requests": "write",
    "issues": "read",
}
# Actions that were already tag-pinned before this flow existed. Every other
# action must carry a full commit SHA.
TAG_PINNED_BEFORE_THIS_FLOW = {"actions/checkout", "oven-sh/setup-bun"}
GATE_CALLERS = (
    "ce-overlay-lock-hold.sh",
    "check-ce-overlay-patches.sh",
    "test-ce-overlay-lock-hold.sh",
    "test-ce-overlay-tooling.sh",
    "test-compound-engineering-overlays.sh",
    "test-ce-overlay-entrystate.sh",
)
STATUS_FUNCTIONS = re.compile(r"\b(always|failure|cancelled)\s*\(")

failures = []


def fail(message):
    failures.append(message)


def run_of(step):
    return str(step.get("run") or "")


def text_of(step):
    return json.dumps(step, sort_keys=True)


def squash(expression):
    return re.sub(r"\s+", " ", str(expression)).strip()


def is_chezmoi_install(step):
    name = str(step.get("name") or "").lower()
    return bool(run_of(step)) and "chezmoi" in name and "install" in name


def steps_of(job):
    return [s for s in (job.get("steps") or []) if isinstance(s, dict)]


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def find_once(steps, label, predicate):
    hits = [i for i, step in enumerate(steps) if predicate(step)]
    if len(hits) != 1:
        fail(f"{LOCK_WORKFLOW}: expected exactly one {label} step, found {len(hits)}")
        return None
    return hits[0]


def check_lock_workflow(workflow_dir):
    path = workflow_dir / LOCK_WORKFLOW
    if not path.exists():
        fail(f"no .github/workflows/{LOCK_WORKFLOW}")
        return
    document = load(path)
    raw = path.read_text(encoding="utf-8")
    jobs = document.get("jobs") or {}
    if not jobs:
        fail(f"{LOCK_WORKFLOW} declares no jobs")
        return

    for name, job in jobs.items():
        timeout = job.get("timeout-minutes")
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
            fail(f"{LOCK_WORKFLOW}: job {name} has no timeout-minutes")
        permissions = job.get("permissions", document.get("permissions"))
        if permissions != LOCK_PERMISSIONS:
            fail(
                f"{LOCK_WORKFLOW}: job {name} holds permissions {permissions!r}, "
                f"expected exactly {LOCK_PERMISSIONS!r}"
            )

    for name, job in jobs.items():
        steps = steps_of(job)
        for step in steps:
            uses = str(step.get("uses") or "")
            if uses.startswith("actions/checkout@"):
                flag = (step.get("with") or {}).get("persist-credentials")
                if flag is not False and str(flag).lower() != "false":
                    fail(f"{LOCK_WORKFLOW}: job {name} has a checkout without persist-credentials: false")
            if "create-pull-request" in uses:
                fail(f"{LOCK_WORKFLOW}: job {name} uses a pull request creation action")
            if re.search(r"gh\s+pr\s+(create|merge)", run_of(step)):
                fail(f"{LOCK_WORKFLOW}: job {name} creates or merges a pull request")

    for name, job in jobs.items():
        for step in steps_of(job):
            uses = str(step.get("uses") or "")
            if not uses:
                continue
            action, _, ref = uses.partition("@")
            if action in TAG_PINNED_BEFORE_THIS_FLOW:
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", ref):
                fail(f"{LOCK_WORKFLOW}: {uses} is not pinned to a full commit SHA")
                continue
            line = re.search(rf"^.*uses:\s*{re.escape(uses)}(.*)$", raw, re.MULTILINE)
            if not line or not re.match(r"\s+#\s*v?\d", line.group(1)):
                fail(f"{LOCK_WORKFLOW}: {uses} has no release tag in a trailing comment")

    if len(jobs) != 1:
        fail(f"{LOCK_WORKFLOW}: expected one job, found {len(jobs)}; update this check for the new shape")
        return
    (job_name, job), = jobs.items()
    steps = steps_of(job)

    resolve = find_once(steps, "resolve", lambda s: "release-lock/src/cli.ts" in run_of(s))
    chezmoi = find_once(steps, "chezmoi install", is_chezmoi_install)
    hold = find_once(steps, "hold", lambda s: ".ci/ce-overlay-lock-hold.sh" in run_of(s))
    digest = find_once(steps, "digest check", lambda s: ".ci/check-release-lock-digests.sh" in run_of(s))
    commit = find_once(steps, "commit", lambda s: re.search(r"git\b.*\bcommit\b", run_of(s), re.DOTALL) is not None)
    push = find_once(steps, "push", lambda s: re.search(r"git push\b", run_of(s)) is not None)
    dispatch = find_once(steps, "dispatch decision", lambda s: "ce-overlay-pr.sh decide" in run_of(s))
    unresolved = find_once(
        steps, "unresolved-source failure", lambda s: "steps.resolve.outputs.exit_code" in str(s.get("if") or "")
    )
    mint = find_once(
        steps, "App token mint", lambda s: str(s.get("uses") or "").startswith("actions/create-github-app-token@")
    )
    order = [resolve, chezmoi, hold, digest, commit, push, dispatch, unresolved]
    if None in order:
        return
    if order != sorted(order) or len(set(order)) != len(order):
        fail(
            f"{LOCK_WORKFLOW}: steps must run in the order resolve, install chezmoi, hold, "
            "digest check, commit, push, dispatch decision, unresolved-source failure"
        )
    if mint is not None and not (commit < mint < push):
        fail(f"{LOCK_WORKFLOW}: the App token must be minted after the commit and before the push")

    hold_id = steps[hold].get("id")
    commit_id = steps[commit].get("id")
    push_id = steps[push].get("id")
    if not (hold_id and commit_id and push_id):
        fail(f"{LOCK_WORKFLOW}: the hold, commit, and push steps need ids for the dispatch condition")
        return

    condition = squash(steps[dispatch].get("if") or "")
    for needle, why in (
        (f"steps.{hold_id}.outputs.candidate == 'yes'", "a rebase candidate"),
        (f"steps.{push_id}.outcome == 'success'", "a successful push"),
        (f"steps.{commit_id}.outputs.changed == 'false'", "nothing to commit"),
        ("github.ref_name == github.event.repository.default_branch", "the default branch"),
    ):
        if needle not in condition:
            fail(f"{LOCK_WORKFLOW}: the dispatch condition does not require {why} ({needle})")
    if STATUS_FUNCTIONS.search(condition):
        fail(f"{LOCK_WORKFLOW}: the dispatch condition uses a status function, so it could run after a failed commit or push")
    dispatch_step = steps[dispatch]
    if "--default-branch" not in run_of(dispatch_step) or "--no-act" in run_of(dispatch_step):
        fail(f"{LOCK_WORKFLOW}: the dispatch step must pass --default-branch and must act")
    branch_env = str((dispatch_step.get("env") or {}).get("DEFAULT_BRANCH") or "")
    if "github.event.repository.default_branch" not in branch_env:
        fail(f"{LOCK_WORKFLOW}: the dispatch step's default branch does not come from the repository's default branch")
    if "::warning::" not in run_of(dispatch_step) or "::error::" in run_of(dispatch_step):
        fail(f"{LOCK_WORKFLOW}: the dispatch step must warn, and never fail, when the dispatch cannot run")

    if mint is None:
        return
    mint_step = steps[mint]
    mint_id = mint_step.get("id")
    if not mint_id:
        fail(f"{LOCK_WORKFLOW}: the App token step needs an id")
        return
    if f"steps.{commit_id}.outputs.changed" not in str(mint_step.get("if") or ""):
        fail(f"{LOCK_WORKFLOW}: the App token is minted even when nothing was committed")
    permissions = {k for k in (mint_step.get("with") or {}) if k.startswith("permission-")}
    if permissions != {"permission-contents"} or mint_step["with"]["permission-contents"] != "write":
        fail(f"{LOCK_WORKFLOW}: the App token must request permission-contents: write and nothing else")

    token = f"steps.{mint_id}.outputs.token"
    for index, step in enumerate(steps):
        if index == push:
            if token in run_of(step) or token in str(step.get("if") or ""):
                fail(f"{LOCK_WORKFLOW}: the push step reads the App token outside its environment")
            if token not in json.dumps(step.get("env") or {}):
                fail(f"{LOCK_WORKFLOW}: the push step does not use the App token")
            if "secrets.GITHUB_TOKEN" not in json.dumps(step.get("env") or {}):
                fail(f"{LOCK_WORKFLOW}: the push step has no GITHUB_TOKEN fallback for a repository without the App")
        elif token in text_of(step):
            fail(f"{LOCK_WORKFLOW}: step {index + 1} reads the App token, which only the push step may use")
        if index != mint and "secrets.CE_LOCK_APP_PRIVATE_KEY" in text_of(step):
            fail(f"{LOCK_WORKFLOW}: step {index + 1} reads the App private key, which only the mint step may use")
    for key, value in (job.get("env") or {}).items():
        if "secrets.CE_LOCK_APP_PRIVATE_KEY" in str(value) and "!= ''" not in str(value):
            fail(f"{LOCK_WORKFLOW}: job env {key} carries the App private key instead of a boolean")


def check_chezmoi_before_gates(workflow_dir):
    for path in sorted(workflow_dir.glob("*.yml")):
        document = load(path)
        for name, job in (document.get("jobs") or {}).items():
            steps = steps_of(job)
            for index, step in enumerate(steps):
                called = [script for script in GATE_CALLERS if script in run_of(step)]
                if not called:
                    continue
                if not any(is_chezmoi_install(earlier) for earlier in steps[:index]):
                    fail(
                        f"{path.name}: job {name} runs {', '.join(called)} without installing "
                        "chezmoi in an earlier step"
                    )


def main():
    root = pathlib.Path(sys.argv[1])
    workflow_dir = root / ".github" / "workflows"
    check_lock_workflow(workflow_dir)
    check_chezmoi_before_gates(workflow_dir)
    for line in failures:
        print(f"check-ce-overlay-wiring: {line}", file=sys.stderr)
    if failures:
        return 1
    print("check-ce-overlay-wiring: ok")
    return 0


sys.exit(main())
PYTHON
