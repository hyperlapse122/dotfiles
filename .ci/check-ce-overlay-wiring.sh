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
# REBASE WORKFLOW (.github/workflows/rebase-ce-overlays.yml)
#   - workflow_dispatch is the only trigger and declares no input; the
#     concurrency group is rebase-ce-overlays without cancellation; the five jobs
#     each have a timeout and exactly the permissions the flow needs
#   - the claude job holds contents: read, has no checkout, id-token, or write
#     secret, depends on prepare, passes its own GITHUB_TOKEN to the action, allows
#     only path-scoped Read and Edit (and no Bash, web, or MCP tool), scans its
#     edited files for tokens before its only upload, and never uploads or reads
#     the execution file outside the classifier
#   - CE_REBASE_TOKEN reaches only the preflight step and the open and await
#     steps, and those steps never see GITHUB_TOKEN; the App private key reaches
#     only a mint step or a boolean check
#   - no run block holds an expression, a pull request is opened only by the
#     script, every checkout drops its credentials, new actions are pinned to a
#     full commit SHA
#   - the owner check precedes the prerequisite check, the record job runs under
#     always() after every job with issues: write, and the publish steps run in
#     the order verify, finish, lock, validate, latest, marker, open, await with
#     the gate, the offline test, and the digest check before the pull request
#   - the publish verify step runs against fixture artifacts (a symbolic link, a
#     hard link, a parent segment, an extra file, an oversized file, a token, a
#     missing file, an unclean class, a linked work file) and ends each as genuine
#   - the branch prefix in .ci/ce-overlay-pr.sh, the workflow, the ce-overlay-rebase
#     package, and the review condition is one string; neither the workflow nor
#     the prompt file contains a mention that would start claude.yml
# REVIEW WORKFLOW (.github/workflows/claude-code-review.yml)
#   - every job has a timeout, and the review job skips only a same-repository
#     head with the rebase branch prefix
# EVERY WORKFLOW
#   - a job that calls the hold script, the upstream gate, or an offline overlay
#     test installs chezmoi in an earlier step, because the gate renders the
#     roster's authoring effort
# DOCUMENTATION (AGENTS.md)
#   - names CE_REBASE_TOKEN, base.json, home/.chezmoidata/ce-overlay-rebase.json,
#     Final delivery, and the auto-merge setting
#   - does not name GUARDED_UPSTREAM_VERSION
# NEGATIVE FIXTURES. When run against this repository, the check also applies
# each mutation in .ci/fixtures/ce-overlay-wiring/mutations.json to a scratch copy
# and requires the named assertion to fail, so no assertion is vacuous.

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

"$wiring_python" - "$root" "$repo_root" <<'PYTHON'
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

import yaml

LOCK_WORKFLOW = "refresh-release-lock.yml"
REBASE_WORKFLOW = "rebase-ce-overlays.yml"
REVIEW_WORKFLOW = "claude-code-review.yml"
REBASE_PERMISSIONS = {
    "preflight": {"contents": "read"},
    "prepare": {"contents": "read", "actions": "read", "pull-requests": "read", "issues": "read"},
    "claude": {"contents": "read"},
    "publish": {"contents": "write"},
    "record": {"contents": "write", "issues": "write"},
}
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


parsed = {}


def load(path):
    text = path.read_text(encoding="utf-8")
    if text not in parsed:
        parsed[text] = yaml.safe_load(text) or {}
    return parsed[text]


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


def action_pin_failures(label, jobs, raw):
    for name, job in jobs.items():
        for step in steps_of(job):
            uses = str(step.get("uses") or "")
            if not uses:
                continue
            action, _, ref = uses.partition("@")
            if action in TAG_PINNED_BEFORE_THIS_FLOW:
                continue
            if not re.fullmatch(r"[0-9a-f]{40}", ref):
                fail(f"{label}: {uses} is not pinned to a full commit SHA")
                continue
            line = re.search(rf"^.*uses:\s*{re.escape(uses)}(.*)$", raw, re.MULTILINE)
            if not line or not re.match(r"\s+#\s*v?\d", line.group(1)):
                fail(f"{label}: {uses} has no release tag in a trailing comment")


def as_list(value):
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


def step_key(step, index):
    return str(step.get("id") or step.get("name") or index)


def split_top_level(text):
    parts, depth, current = [], 0, ""
    for char in text:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    if current:
        parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def claude_flags(claude_args):
    tokens = shlex.split(str(claude_args))
    flags = {}
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.startswith("--"):
            value = tokens[index + 1] if index + 1 < len(tokens) and not tokens[index + 1].startswith("--") else ""
            flags[token] = value
            index += 2 if value else 1
        else:
            index += 1
    return flags


def check_claude_job(job, document):
    label = REBASE_WORKFLOW
    steps = steps_of(job)
    permissions = job.get("permissions")
    if permissions != {"contents": "read"}:
        fail(f"{label}: the claude job must hold exactly contents: read, found {permissions!r}")
    if any(str(s.get("uses") or "").startswith("actions/checkout@") for s in steps):
        fail(f"{label}: the claude job checks out the repository")
    if "prepare" not in as_list(job.get("needs")):
        fail(f"{label}: the claude job does not depend on prepare")
    job_text = json.dumps(job, sort_keys=True)
    for forbidden in ("CE_REBASE_TOKEN", "CE_LOCK_APP_PRIVATE_KEY", "secrets.GITHUB_TOKEN", "id-token"):
        if forbidden in job_text:
            fail(f"{label}: the claude job references {forbidden}")
    actions = [
        (i, s) for i, s in enumerate(steps) if str(s.get("uses") or "").startswith("anthropics/claude-code-action@")
    ]
    if len(actions) != 1:
        fail(f"{label}: the claude job must run the Claude action exactly once, found {len(actions)}")
        return
    action_index, action = actions[0]
    downloads = [i for i, s in enumerate(steps) if str(s.get("uses") or "").startswith("actions/download-artifact@")]
    if not downloads or min(downloads) > action_index:
        fail(f"{label}: the claude job must download the work directory before it runs Claude")
    if action.get("timeout-minutes") != 15:
        fail(f"{label}: the Claude step must have a 15-minute timeout")
    arguments = action.get("with") or {}
    if arguments.get("github_token") != "${{ github.token }}":
        fail(f"{label}: the Claude action's github_token input must be the job's GITHUB_TOKEN")
    if arguments.get("claude_code_oauth_token") != "${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}":
        fail(f"{label}: the Claude action must use CLAUDE_CODE_OAUTH_TOKEN")
    for index, step in enumerate(steps):
        if index != action_index and "CLAUDE_CODE_OAUTH_TOKEN" in text_of(step):
            fail(f"{label}: step {index + 1} of the claude job reads the Claude OAuth token")
    flags = claude_flags(arguments.get("claude_args", ""))
    if flags.get("--model") != "claude-sonnet-5":
        fail(f"{label}: the Claude step must use the model claude-sonnet-5")
    if flags.get("--permission-mode") != "dontAsk":
        fail(f"{label}: the Claude step must use --permission-mode dontAsk")
    tools = set(split_top_level(flags.get("--tools", "")))
    if not tools or not tools <= {"Read", "Edit", "Write"}:
        fail(f"{label}: --tools must list only Read, Edit, and Write, found {sorted(tools)!r}")
    allowed = split_top_level(flags.get("--allowedTools", ""))
    workdir = "/${{ github.workspace }}/ce-rebase-work/"
    kinds = set()
    for rule in allowed:
        match = re.fullmatch(r"(\w+)\((.*)\)", rule)
        if not match or match.group(1) not in {"Read", "Edit", "Write"}:
            fail(f"{label}: --allowedTools holds {rule!r}, which is not a path-scoped Read, Edit, or Write rule")
            continue
        kind, scope = match.groups()
        kinds.add(kind)
        needed = workdir + ("" if kind == "Read" else "files/")
        if not scope.startswith(needed) or not scope.endswith("**"):
            fail(f"{label}: --allowedTools rule {rule!r} is not scoped to {needed}")
    if not {"Read", "Edit"} <= kinds:
        fail(f"{label}: --allowedTools must allow Read and Edit on the work directory")
    denied = set(split_top_level(flags.get("--disallowedTools", "")))
    for name in ("Bash", "WebFetch", "WebSearch", "mcp__*"):
        if name not in denied:
            fail(f"{label}: --disallowedTools does not deny {name}")
    if re.search(r"@claude", json.dumps(arguments), re.IGNORECASE):
        fail(f"{label}: the Claude action inputs contain @claude")

    uploads = [(i, s) for i, s in enumerate(steps) if str(s.get("uses") or "").startswith("actions/upload-artifact@")]
    if len(uploads) != 1:
        fail(f"{label}: the claude job must upload exactly once, found {len(uploads)}")
    else:
        upload_index, upload = uploads[0]
        upload_with = upload.get("with") or {}
        if upload_with.get("name") != "ce-rebase-claude" or not str(upload_with.get("path", "")).endswith("ce-claude-out"):
            fail(f"{label}: the claude job must upload only the ce-claude-out directory as ce-rebase-claude")
        if "execution_file" in text_of(upload):
            fail(f"{label}: the claude job uploads the execution file")
        scans = [i for i, s in enumerate(steps) if "TOKEN_SHAPE" in run_of(s)]
        if not scans or min(scans) > upload_index:
            fail(f"{label}: the claude job must scan the edited files for tokens before its upload")
    for index, step in enumerate(steps):
        if "execution_file" in text_of(step) and step.get("id") != "classify":
            fail(f"{label}: step {index + 1} of the claude job reads the execution file; only the classifier may")
    for name, other in (document.get("jobs") or {}).items():
        if name != "claude" and any(
            str(s.get("uses") or "").startswith("anthropics/claude-code-action@") for s in steps_of(other)
        ):
            fail(f"{label}: job {name} runs the Claude action; only the claude job may")


def secret_hits(document, token):
    hits = []
    if token in json.dumps(document.get("env") or {}):
        hits.append(("<workflow env>", "<env>", None))
    for name, job in (document.get("jobs") or {}).items():
        if token in json.dumps(job.get("env") or {}):
            hits.append((name, "<job env>", None))
        for index, step in enumerate(steps_of(job)):
            if token in text_of(step):
                hits.append((name, step_key(step, index), step))
    return hits


def check_secret_placement(document):
    label = REBASE_WORKFLOW
    allowed_rebase = {("preflight", "preflight"), ("publish", "open"), ("publish", "await")}
    for name, key, _ in secret_hits(document, "CE_REBASE_TOKEN"):
        if (name, key) not in allowed_rebase:
            fail(f"{label}: CE_REBASE_TOKEN appears in {name} ({key}); only the preflight job and the open and await steps may use it")
    for job_name, key in allowed_rebase:
        if not any(n == job_name and k == key for n, k, _ in secret_hits(document, "CE_REBASE_TOKEN")):
            fail(f"{label}: the {key} step of {job_name} does not receive CE_REBASE_TOKEN")
    for name, key, step in secret_hits(document, "CE_LOCK_APP_PRIVATE_KEY"):
        text = json.dumps(document["jobs"][name].get("env") or {}) if step is None else text_of(step)
        if step is not None and str(step.get("uses") or "").startswith("actions/create-github-app-token@"):
            if text.count("secrets.CE_LOCK_APP_PRIVATE_KEY") != 1 or "private-key" not in json.dumps(step.get("with") or {}):
                fail(f"{label}: the App token mint step in {name} uses the private key outside its private-key input")
            continue
        occurrences = text.count("secrets.CE_LOCK_APP_PRIVATE_KEY")
        booleans = len(re.findall(r"secrets\.CE_LOCK_APP_PRIVATE_KEY\s*!=\s*''", text))
        if name == "<workflow env>" or occurrences != booleans:
            fail(f"{label}: the App private key appears in {name} ({key}) outside a mint step or a boolean check")
    for name, job in (document.get("jobs") or {}).items():
        for index, step in enumerate(steps_of(job)):
            if str(step.get("uses") or "").startswith("actions/create-github-app-token@"):
                permissions = {k for k in (step.get("with") or {}) if k.startswith("permission-")}
                if permissions != {"permission-contents"} or step["with"]["permission-contents"] != "write":
                    fail(f"{label}: the App token in {name} must request permission-contents: write and nothing else")


def verify_scenarios(document, job):
    label = REBASE_WORKFLOW
    steps = steps_of(job)
    verify = [s for s in steps if s.get("id") == "verify"]
    if len(verify) != 1 or not run_of(verify[0]):
        fail(f"{label}: publish must have exactly one verify step that runs a script")
        return
    script = run_of(verify[0])
    shape = (document.get("env") or {}).get("TOKEN_SHAPE", "")
    keys = ("skills/a/one.md", "skills/b/two.sh")
    modes = {keys[0]: "0644", keys[1]: "0755"}

    def scenario(name, expect_ok, build, manifest_keys=keys):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            work, incoming, out = base / "ce-rebase-work", base / "ce-claude-in", base / "out"
            for key in keys:
                (work / "files" / pathlib.Path(key).parent).mkdir(parents=True, exist_ok=True)
                (work / "files" / key).write_text("trusted\n", encoding="utf-8")
                (incoming / "files" / pathlib.Path(key).parent).mkdir(parents=True, exist_ok=True)
                (incoming / "files" / key).write_text("edited\n", encoding="utf-8")
            (incoming / "class.txt").write_text("none\n", encoding="utf-8")
            manifest = {
                "baseTag": "compound-engineering-v3.26.3",
                "targetTag": "compound-engineering-v3.27.0",
                "paths": {k: {"route": "conflict", "mode": modes.get(k, "0644")} for k in manifest_keys},
                "conflicted": list(manifest_keys),
            }
            (work / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            out.write_text("", encoding="utf-8")
            build(work, incoming)
            env = {
                "PATH": "/usr/bin:/bin",
                "STATE": "claude",
                "WORK": str(work),
                "INCOMING": str(incoming),
                "GITHUB_OUTPUT": str(out),
                "WORK_FILE_MAX_BYTES": "64",
                "TOKEN_SHAPE": shape,
            }
            proc = subprocess.run(
                ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                env=env, capture_output=True, text=True, check=False,
            )
            outputs = out.read_text(encoding="utf-8")
            if expect_ok:
                copied = (work / "files" / keys[0]).read_text(encoding="utf-8") == "edited\n"
                mode = oct((work / "files" / keys[1]).stat().st_mode & 0o777)
                if proc.returncode != 0 or not copied or mode != "0o755":
                    fail(f"{label}: the verify step rejected or mishandled a clean artifact ({name}): {proc.stderr.strip()}")
                return
            untouched = all((work / "files" / k).read_text(encoding="utf-8") == "trusted\n" for k in keys if (work / "files" / k).exists())
            if proc.returncode == 0 or "class=genuine" not in outputs or not untouched:
                fail(f"{label}: the verify step accepted {name}, or did not end it as genuine without changing the work directory")

    def make_symlink(work, incoming):
        target = incoming / "files" / keys[0]
        target.unlink()
        target.symlink_to("/etc/passwd")

    def make_hardlink(work, incoming):
        second = incoming / "files" / keys[1]
        second.unlink()
        os.link(incoming / "files" / keys[0], second)

    def make_extra(work, incoming):
        (incoming / "files" / "extra.md").write_text("x\n", encoding="utf-8")

    def make_oversized(work, incoming):
        (incoming / "files" / keys[0]).write_text("x" * 65, encoding="utf-8")

    def make_token(work, incoming):
        (incoming / "files" / keys[0]).write_text("ghp_" + "A" * 30 + "\n", encoding="utf-8")

    def make_missing(work, incoming):
        (incoming / "files" / keys[1]).unlink()

    def make_class(work, incoming):
        (incoming / "class.txt").write_text("outage\n", encoding="utf-8")

    def make_trusted_link(work, incoming):
        decoy = work.parent / "decoy"
        decoy.write_text("trusted\n", encoding="utf-8")
        target = work / "files" / keys[0]
        target.unlink()
        target.symlink_to(decoy)

    scenario("a clean artifact", True, lambda w, i: None)
    scenario("a symbolic link", False, make_symlink)
    scenario("a hard link", False, make_hardlink)
    scenario("a path with a parent segment", False, lambda w, i: None, manifest_keys=("skills/../evil", keys[1]))
    scenario("an extra file", False, make_extra)
    scenario("an oversized file", False, make_oversized)
    scenario("a token-shaped string", False, make_token)
    scenario("a missing conflicted file", False, make_missing)
    scenario("an unclean class file", False, make_class)
    scenario("a symbolic link in the trusted work directory", False, make_trusted_link)


def check_rebase_workflow(workflow_dir, aux_root, dynamic=True):
    label = REBASE_WORKFLOW
    path = workflow_dir / label
    if not path.exists():
        fail(f"no .github/workflows/{label}")
        return
    document = load(path)
    raw = path.read_text(encoding="utf-8")
    trigger = document.get("on", document.get(True))
    if not isinstance(trigger, dict) or set(trigger) != {"workflow_dispatch"}:
        fail(f"{label}: workflow_dispatch must be the only trigger")
    elif trigger["workflow_dispatch"] not in (None, {}):
        fail(f"{label}: workflow_dispatch must declare no input")
    if document.get("concurrency") != {"group": "rebase-ce-overlays", "cancel-in-progress": False}:
        fail(f"{label}: the concurrency group must be rebase-ce-overlays with cancel-in-progress: false")
    if document.get("permissions") != {}:
        fail(f"{label}: the workflow token must default to no permissions")
    jobs = document.get("jobs") or {}
    if set(jobs) != set(REBASE_PERMISSIONS):
        fail(f"{label}: expected the jobs {sorted(REBASE_PERMISSIONS)}, found {sorted(jobs)}")
        return
    for name, job in jobs.items():
        timeout = job.get("timeout-minutes")
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
            fail(f"{label}: job {name} has no timeout-minutes")
        if job.get("permissions") != REBASE_PERMISSIONS[name]:
            fail(f"{label}: job {name} holds permissions {job.get('permissions')!r}, expected {REBASE_PERMISSIONS[name]!r}")
        for step in steps_of(job):
            uses = str(step.get("uses") or "")
            if uses.startswith("actions/checkout@"):
                flag = (step.get("with") or {}).get("persist-credentials")
                if flag is not False and str(flag).lower() != "false":
                    fail(f"{label}: job {name} has a checkout without persist-credentials: false")
            run = run_of(step)
            if "${{" in run:
                fail(f"{label}: job {name} interpolates an expression in a run block; pass it through env")
            if re.search(r"gh\s+pr\s+(create|merge)|--admin|--squash", run):
                fail(f"{label}: job {name} creates or merges a pull request outside .ci/ce-overlay-pr.sh")
    action_pin_failures(label, jobs, raw)
    if re.search(r"@claude", raw, re.IGNORECASE):
        fail(f"{label}: the workflow contains @claude")

    check_claude_job(jobs["claude"], document)
    check_secret_placement(document)

    for name, job in jobs.items():
        for index, step in enumerate(steps_of(job)):
            if re.search(r"github\.token|GITHUB_TOKEN|GH_TOKEN", text_of(step)) and (
                (name == "preflight" and step.get("id") == "preflight")
                or (name == "publish" and step.get("id") in ("open", "await"))
            ):
                fail(f"{label}: pull request step {step_key(step, index)} in {name} takes a token from GITHUB_TOKEN")
    for scope in (document.get("env") or {}, jobs["publish"].get("env") or {}, jobs["preflight"].get("env") or {}):
        if re.search(r"github\.token|GITHUB_TOKEN|GH_TOKEN", json.dumps(scope)):
            fail(f"{label}: a workflow or job env exposes GITHUB_TOKEN to the pull request steps")

    preflight = steps_of(jobs["preflight"])
    ids = [s.get("id") for s in preflight]
    if "actor" not in ids or "preflight" not in ids or ids.index("actor") > ids.index("preflight"):
        fail(f"{label}: the owner check must run before the prerequisite check in the preflight job")
    else:
        actor = preflight[ids.index("actor")]
        actor_env = actor.get("env") or {}
        if actor_env.get("ACTOR") != "${{ github.actor }}" or actor_env.get("OWNER") != "${{ github.repository_owner }}":
            fail(f"{label}: the owner check must compare github.actor with github.repository_owner")
        if '"$ACTOR" = "$OWNER"' not in run_of(actor) or "exit 1" not in run_of(actor):
            fail(f"{label}: the owner check must stop an actor that is not the owner")
    if "preflight" not in as_list(jobs["prepare"].get("needs")):
        fail(f"{label}: the prepare job does not depend on preflight")
    prepare_steps = steps_of(jobs["prepare"])
    if not any(".ci/ce-overlay-rebase.sh prepare" in run_of(s) for s in prepare_steps):
        fail(f"{label}: the prepare job does not run the rebase driver prepare step")
    guard = [s for s in prepare_steps if "ce-overlay-pr.sh decide" in run_of(s)]
    if len(guard) != 1 or "--no-act" not in run_of(guard[0]) or "--exclude-run" not in run_of(guard[0]):
        fail(f"{label}: the prepare job needs one guard step: decide --no-act --exclude-run")

    record = jobs["record"]
    condition = squash(record.get("if") or "")
    if "always()" not in condition or re.search(r"\bsuccess\s*\(", condition):
        fail(f"{label}: the record job must run under if: always()")
    if set(as_list(record.get("needs"))) != {"preflight", "prepare", "claude", "publish"}:
        fail(f"{label}: the record job must depend on every other job")
    if (record.get("permissions") or {}).get("issues") != "write":
        fail(f"{label}: the record job must hold issues: write")

    publish = jobs["publish"]
    steps = steps_of(publish)
    order = [s.get("id") for s in steps]
    sequence = ["verify", "finish", "lock", "validate", "latest", "marker", "open", "await"]
    if any(item not in order for item in sequence):
        fail(f"{label}: the publish job lacks one of the steps {sequence}")
    else:
        positions = [order.index(item) for item in sequence]
        if positions != sorted(positions):
            fail(f"{label}: the publish steps must run in the order {sequence}")
        readers = [
            s.get("id") for s in steps
            if ("INCOMING" in text_of(s) or "ce-claude-in" in text_of(s))
            and not str(s.get("uses") or "").startswith("actions/download-artifact@")
        ]
        if readers != ["verify"]:
            fail(f"{label}: only the verify step may read the Claude artifact, found {readers}")
        marker = steps[order.index("marker")]
        if "customization == 'changed'" not in str(marker.get("if") or "") or "--event awaiting-review" not in run_of(marker):
            fail(f"{label}: the marker step must run only for a changed customization and record awaiting-review")
        open_step = steps[order.index("open")]
        if "--customization-lines" not in run_of(open_step) or "--base" not in run_of(open_step):
            fail(f"{label}: the open step must pass --customization-lines and --base")
        gates = [s for s in steps if ".ci/check-ce-overlay-patches.sh" in run_of(s)]
        if len(gates) != 1 or order.index(gates[0].get("id")) > order.index("open"):
            fail(f"{label}: the upstream gate must run once, before the pull request opens")
        for needle in ("test-compound-engineering-overlays.sh", "check-release-lock-digests.sh"):
            if not any(needle in run_of(s) for s in steps[: order.index("open")]):
                fail(f"{label}: {needle} must run before the pull request opens")
        latest = steps[order.index("latest")]
        if "release-lock/src/cli.ts --only compound-engineering" not in run_of(latest):
            fail(f"{label}: the publish job must re-resolve the latest release before it opens the pull request")
    if dynamic:
        verify_scenarios(document, publish)

    prefix = branch_prefix(aux_root)
    if prefix is None:
        fail("the branch prefix constant BRANCH_PREFIX is missing from .ci/ce-overlay-pr.sh")
    elif prefix not in raw:
        fail(f"{label}: the workflow does not name the rebase branch prefix {prefix}")
    prompt = aux_root / ".github" / "prompts" / "ce-overlay-rebase.md"
    if not prompt.exists():
        fail("no .github/prompts/ce-overlay-rebase.md")
    elif re.search(r"@claude", prompt.read_text(encoding="utf-8"), re.IGNORECASE):
        fail("the rebase prompt contains @claude")
    package_dir = aux_root / "packages" / "ce-overlay-rebase" / "src"
    for name in ("marker.ts", "decide.ts", "classify.ts", "cli.ts"):
        if not (package_dir / name).exists():
            fail(f"packages/ce-overlay-rebase/src/{name} is missing")
    if prefix is not None and package_dir.exists():
        for source in package_dir.glob("*.ts"):
            for found in re.findall(r"chore/rebase[A-Za-z0-9./_-]*", source.read_text(encoding="utf-8")):
                if not found.startswith(prefix):
                    fail(f"{source.name} names a rebase branch prefix that differs from {prefix}")


def branch_prefix(aux_root):
    script = aux_root / ".ci" / "ce-overlay-pr.sh"
    if not script.exists():
        return None
    match = re.search(r"^BRANCH_PREFIX='([^']+)'", script.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1) if match else None


def check_review_workflow(workflow_dir, aux_root):
    label = REVIEW_WORKFLOW
    path = workflow_dir / label
    if not path.exists():
        fail(f"no .github/workflows/{label}")
        return
    document = load(path)
    jobs = document.get("jobs") or {}
    for name, job in jobs.items():
        timeout = job.get("timeout-minutes")
        if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout <= 0:
            fail(f"{label}: job {name} has no timeout-minutes")
    job = jobs.get("claude-review")
    if job is None:
        fail(f"{label}: the claude-review job is missing")
        return
    condition = squash(job.get("if") or "")
    match = re.fullmatch(
        r"\$\{\{ ?!\( ?startsWith\(github\.event\.pull_request\.head\.ref, ?'([^']+)'\) ?&& ?"
        r"github\.event\.pull_request\.head\.repo\.full_name == github\.repository ?\) ?\}\}",
        condition,
    )
    if not match:
        fail(f"{label}: the claude-review condition must skip only a same-repository head with the rebase branch prefix")
        return
    prefix = branch_prefix(aux_root)
    if prefix is not None and match.group(1) != prefix:
        fail(f"{label}: the branch prefix {match.group(1)} differs from {prefix} in .ci/ce-overlay-pr.sh")


def run_checks(root, aux_root, dynamic=True):
    del failures[:]
    workflow_dir = root / ".github" / "workflows"
    check_lock_workflow(workflow_dir)
    check_rebase_workflow(workflow_dir, aux_root, dynamic)
    check_review_workflow(workflow_dir, aux_root)
    check_chezmoi_before_gates(workflow_dir)
    check_documentation(root, aux_root)
    return list(failures)


def self_test(repo_root):
    table_path = repo_root / ".ci" / "fixtures" / "ce-overlay-wiring" / "mutations.json"
    cases = json.loads(table_path.read_text(encoding="utf-8"))
    problems = []
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            tree = pathlib.Path(tmp)
            shutil.copytree(repo_root / ".github" / "workflows", tree / ".github" / "workflows")
            shutil.copytree(repo_root / ".github" / "prompts", tree / ".github" / "prompts")
            (tree / ".ci").mkdir()
            shutil.copy(repo_root / ".ci" / "ce-overlay-pr.sh", tree / ".ci" / "ce-overlay-pr.sh")
            (tree / "packages" / "ce-overlay-rebase").mkdir(parents=True)
            shutil.copytree(
                repo_root / "packages" / "ce-overlay-rebase" / "src",
                tree / "packages" / "ce-overlay-rebase" / "src",
            )
            target = tree / case["file"]
            text = target.read_text(encoding="utf-8")
            for old, new in case["replace"]:
                if old not in text:
                    problems.append(f"mutation {case['name']!r} no longer applies: {old!r} is not in {case['file']}")
                    break
                text = text.replace(old, new, 1)
            else:
                target.write_text(text, encoding="utf-8")
                found = run_checks(tree, tree, dynamic=any(word in case["expect"] for word in ("accepted", "mishandled")))
                if not any(case["expect"] in line for line in found):
                    problems.append(
                        f"mutation {case['name']!r} was not rejected with {case['expect']!r}; got {found!r}"
                    )
    return problems


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


def check_documentation(root, aux_root):
    agents_md = root / "AGENTS.md"
    if not agents_md.exists():
        agents_md = aux_root / "AGENTS.md"
    if not agents_md.exists():
        return
    text = agents_md.read_text(encoding="utf-8")
    for needle in (
        "CE_REBASE_TOKEN",
        "base.json",
        "home/.chezmoidata/ce-overlay-rebase.json",
        "Final delivery",
    ):
        if needle not in text:
            fail(f"AGENTS.md: missing documentation for {needle!r}")
    if "auto-merge" not in text:
        fail("AGENTS.md: missing documentation for the auto-merge setting")
    if "GUARDED_UPSTREAM_VERSION" in text:
        fail("AGENTS.md: still names retired GUARDED_UPSTREAM_VERSION")

def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    repo_root = pathlib.Path(sys.argv[2]).resolve()
    aux_root = root if (root / ".ci" / "ce-overlay-pr.sh").exists() else repo_root
    found = run_checks(root, aux_root)
    if root == repo_root:
        found += self_test(repo_root)
    for line in found:
        print(f"check-ce-overlay-wiring: {line}", file=sys.stderr)
    if found:
        return 1
    print("check-ce-overlay-wiring: ok")
    return 0


sys.exit(main())
PYTHON
