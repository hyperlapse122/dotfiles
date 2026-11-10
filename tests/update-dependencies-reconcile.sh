#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/update-dependencies-reconcile.sh <update-dependencies-workflow> <gitignore>
#
# Covers .github/workflows/update-dependencies.yml end-to-end:
#
# - Parses the workflow structurally with `yq` + `jq`:
#   - cron fires twice an hour, 30 minutes apart, and never at minute 0;
#   - no step runs `gh pr merge` and neither catalog key appears;
#   - step `if:` conditions on `Verify updates`, `Push verified updates directly
#     to main`, and `Open reconciliation PR on failure` match their exact gates.
# - Runs `Update flake inputs, agent plugins, and packages` against an
#   argument-checking `nix` stub:
#   - `nix flake update`, `compound-engineering-plugin` resolution and locking
#     across `flake.nix`, `home/h82/agents/agent-plugin-pins.nix`, and
#     `flake.lock` (including refusal of an unusable locked rev), and every
#     release runner (`claude-desktop-release`, `claude-code-release`,
#     `android-sdk-release`, `mise-release`, `chatgpt-release`,
#     `t3code-release`, `antigravity-cli-release`, `wifiman-desktop-release`,
#     `omp-release`, `npm-release` for `acpx` and `claude-agent-sdk`,
#     `codex-release`, `grok-build-release`, `antigravity-acp-release`);
#   - soft-failing updaters (`chatgpt-release`, `t3code-release`,
#     `antigravity-cli-release`, `wifiman-desktop-release`, `omp-release`,
#     `npm-release` for `acpx` and `claude-agent-sdk`, `codex-release`,
#     `grok-build-release`, `antigravity-acp-release`) emit `::warning`, restore
#     their pin (and lock file for the npm packages), and let the remaining
#     updates continue;
#   - a failing `antigravity-acp-release` leaves a T3 Code bump already in
#     `packages/t3code-release.json` in place.
# - Runs `Verify updates` under `bash -e` (without `pipefail`):
#   - `nix fmt`, `nix flake check`, and `.#vmChecks.all` failing in turn each
#     report `status=failure`; all succeeding reports `status=success`;
#   - VM build output lands in `vm-check.log`, never `check.log`.
# - Runs `Push verified updates directly to main` against a sandboxed git
#   remote initialized with the repository's real `.gitignore`:
#   - per-pin bump commits (`compound-engineering`, `t3code`, `omp`, `acpx`,
#     `grok-build`, `antigravity-cli`, `antigravity-acp`, etc.) each land with their exact commit message and only their own files;
#   - unchanged `origin/main` commits before `git rebase` and never sweeps
#     `fmt.log`, `check.log`, or `vm-check.log` into `git add -A`;
#   - diverged `origin/main` rebases cleanly and pushes both commits.
# - Runs `Open reconciliation PR on failure` against a stub `gh` that rejects
#   `--label`:
#   - with no open PR, pushes `update-dependencies-fix` and opens the PR;
#   - with an open PR, preserves the branch and refreshes the PR body;
#   - when the open-PR query fails, exits non-zero without touching the branch
#     or any PR.

set -euo pipefail

workflow=${1:-}
gitignore=${2:-}
if [[ $# -ne 2 || -z $workflow || ! -f $workflow || -z $gitignore || ! -f $gitignore ]]; then
  printf 'usage: %s WORKFLOW_FILE GITIGNORE_FILE\n' "${0##*/}" >&2
  exit 2
fi

fail() { printf 'update-dependencies-reconcile: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'update-dependencies-reconcile: ok - %s\n' "$*"; }

for tool in git jq yq; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
git_bin=$(command -v git)

fix_branch=update-dependencies-fix

wf_json=$(yq -o=json '.' "$workflow")
[[ $(jq '.jobs | length' <<<"$wf_json") == 1 ]] || fail "expected one job in $workflow"
job=$(jq '.jobs["update-dependencies"] // empty' <<<"$wf_json")
[[ -n $job ]] || fail "missing update-dependencies job in $workflow"

step_by_name() {
  jq -e --arg n "$1" '.steps[] | select(.name == $n)' <<<"$job"
}

step_run() {
  step_by_name "$1" | jq -r '.run // empty'
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/update-dependencies-reconcile.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# setup_clone <name>: a bare origin with main and a clone of it seeded with
# the repository's real .gitignore and baseline pin files.
setup_clone() {
  local name=$1
  local origin=$scratch/$name-origin.git
  local clone=$scratch/$name-clone
  "$git_bin" init -q --bare "$origin"
  "$git_bin" -C "$origin" config init.defaultBranch main
  "$git_bin" --git-dir "$origin" symbolic-ref HEAD refs/heads/main
  "$git_bin" clone -q "$origin" "$clone"
  "$git_bin" -C "$clone" config user.email t@example.invalid
  "$git_bin" -C "$clone" config user.name Test
  "$git_bin" -C "$clone" checkout -qb main
  cp "$gitignore" "$clone/.gitignore"
  cat >"$clone/flake.nix" <<'EOF'
{
  inputs.compound-engineering-plugin.url = "github:EveryInc/compound-engineering-plugin/compound-engineering-v2.67.0";
}
EOF
  cat >"$clone/flake.lock" <<'EOF'
{
  "nodes": {
    "compound-engineering-plugin": {
      "locked": {
        "rev": "1111111111111111111111111111111111111111"
      }
    }
  }
}
EOF
  mkdir -p "$clone/home/h82/agents" "$clone/packages/acpx" "$clone/packages/claude-agent-sdk"
  cat >"$clone/home/h82/agents/agent-plugin-pins.nix" <<'EOF'
{
  compound-engineering = {
    tag = "compound-engineering-v2.67.0";
    expectedRev = "1111111111111111111111111111111111111111";
  };
}
EOF
  printf '{"version": "1.0.0"}\n' >"$clone/packages/claude-desktop-version.json"
  printf '{"version": "1.0.0"}\n' >"$clone/packages/claude-code-manifest.json"
  printf '{"latest": {"cmdline-tools": "19.0"}}\n' >"$clone/packages/android-sdk-repo.json"
  printf '{"version": "2026.10.0"}\n' >"$clone/packages/mise-release.json"
  printf '{"version": "1.0.0"}\n' >"$clone/packages/chatgpt-version.json"
  printf '{"version": "0.0.46-nightly.20261003.2600"}\n' >"$clone/packages/t3code-release.json"
  printf '{"version": "1.0.0"}\n' >"$clone/packages/wifiman-desktop-version.json"
  printf '{"version": "1.4.8", "platforms": {}}\n' >"$clone/packages/antigravity-cli-release.json"
  printf '{"version": "1.4.3", "platforms": {}}\n' >"$clone/packages/antigravity-acp-release.json"
  printf '{"version": "1.4.0", "platforms": {}}\n' >"$clone/packages/omp-release.json"
  printf '{"version": "0.20.0"}\n' >"$clone/packages/acpx-release.json"
  printf '{"lockfileVersion": 3, "name": "acpx"}\n' >"$clone/packages/acpx/package-lock.json"
  printf '{"version": "0.3.311"}\n' >"$clone/packages/claude-agent-sdk-release.json"
  printf '{"lockfileVersion": 3, "name": "claude-agent-sdk"}\n' >"$clone/packages/claude-agent-sdk/package-lock.json"
  printf '{"version": "0.50.0"}\n' >"$clone/packages/codex-release.json"
  printf '{"version": "1.0.62", "platforms": {}}\n' >"$clone/packages/grok-build-release.json"
  printf 'base\n' >"$clone/tracked.txt"
  "$git_bin" -C "$clone" add -A
  "$git_bin" -C "$clone" commit -qm init
  "$git_bin" -C "$clone" push -q origin main
  printf '%s %s\n' "$origin" "$clone"
}

# --- reconciliation PR step -------------------------------------------------

pr_step=$(step_by_name 'Open reconciliation PR on failure') ||
  fail "could not find the reconciliation PR step in $workflow"
[[ $(jq -r '.env.BRANCH // empty' <<<"$pr_step") == "$fix_branch" ]] ||
  fail "the reconciliation PR step does not set BRANCH to $fix_branch"
pr_script=$(jq -r '.run // empty' <<<"$pr_step")
[[ -n $pr_script ]] || fail "could not find the reconciliation PR step's run block in $workflow"

run_pr_step() {
  local name=$1 mode=$2 want=$3 origin clone status=0
  read -r origin clone <<<"$(setup_clone "$name")"
  if [[ $mode != none ]]; then
    "$git_bin" -C "$clone" checkout -qb "$fix_branch"
    printf 'fix\n' >"$clone/fix.txt"
    "$git_bin" -C "$clone" add fix.txt
    "$git_bin" -C "$clone" commit -qm 'fix: reconcile the update'
    "$git_bin" -C "$clone" push -q origin "$fix_branch"
    "$git_bin" -C "$clone" checkout -q main
  fi
  mkdir -p "$scratch/$name-bin"
  cat >"$scratch/$name-bin/gh" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$scratch/$name-gh.log"
prev=
jq=0
open=0
for arg in "\$@"; do
  if [[ \$arg == --label || \$arg == --label=* || \$arg == --add-label* ]]; then
    echo "could not add label: 'dependencies' not found" >&2
    exit 1
  fi
  if [[ \$prev == --body-file ]]; then cp "\$arg" "$scratch/$name-body.md"; fi
  if [[ \$arg == --jq || \$arg == -q ]]; then jq=1; fi
  if [[ \$prev == --state && \$arg == open ]]; then open=1; fi
  prev=\$arg
done
if [[ $mode == error && \$1 == pr && ( \$2 == list || \$2 == view ) ]]; then
  echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2
  exit 1
fi
if [[ \$1 == pr && \$2 == list ]] && ((open)); then
  case $mode in
    open) if ((jq)); then echo 1; else echo '[{"number":7}]'; fi ;;
    *) if ((jq)); then echo 0; else echo '[]'; fi ;;
  esac
  exit 0
fi
if [[ \$1 == pr && \$2 == view ]]; then
  echo 'no pull requests found' >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$scratch/$name-bin/gh"
  : >"$scratch/$name-gh.log"
  printf 'changed\n' >>"$clone/tracked.txt"
  printf 'nix flake check output\n' >"$clone/check.log"
  printf 'nix build vmChecks output\n' >"$clone/vm-check.log"
  (
    cd "$clone"
    PATH=$scratch/$name-bin:$PATH BRANCH=$fix_branch \
      bash -e -c "$pr_script"
  ) >"$scratch/$name-step.log" 2>&1 || status=$?
  if ((want == 0 && status != 0)); then
    fail "the reconciliation PR step exited $status ($name): $(tail -n 5 "$scratch/$name-step.log")"
  elif ((want != 0 && status == 0)); then
    fail "the reconciliation PR step exited 0 ($name): $(tail -n 5 "$scratch/$name-step.log")"
  fi
  printf '%s\n' "$origin"
}

origin=$(run_pr_step create none 0)
"$git_bin" --git-dir "$origin" rev-parse -q --verify "refs/heads/$fix_branch" >/dev/null ||
  fail "with no open PR, the step did not push $fix_branch"
pushed=$("$git_bin" --git-dir "$origin" log -1 --format=%s "$fix_branch")
[[ $pushed == "chore(deps): automated dependency update (reconciliation required)" ]] ||
  fail "with no open PR, $fix_branch does not carry this run's update: $pushed"
grep -q '^pr create' "$scratch/create-gh.log" ||
  fail "with no open PR, the step did not run gh pr create: $(cat "$scratch/create-gh.log")"
pass "with no open PR and no labels, the step pushes $fix_branch, opens the PR, and exits 0"

check_body() {
  local body
  body=$(cat "$scratch/$1-body.md")
  [[ $body == *"Push a fix to this branch"* ]] || fail "the $1 PR body does not ask for a fix to be pushed"
  [[ $body != *hourly* ]] || fail "the $1 PR body still calls the updater hourly"
  [[ $body != *"merged automatically"* ]] || fail "the $1 PR body still promises an automatic merge"
  [[ $body != *Claude* ]] || fail "the $1 PR body still mentions Claude"
}

check_body create
pass 'the created PR body asks for a fix and neither calls the updater hourly, promises an automatic merge, nor mentions Claude'

origin=$(run_pr_step open open 0)
head_subject=$("$git_bin" --git-dir "$origin" log -1 --format=%s "$fix_branch")
[[ $head_subject == 'fix: reconcile the update' ]] ||
  fail "with a PR already open, the step reset $fix_branch over its fix commit; its head is now: $head_subject"
grep -q '^pr edit' "$scratch/open-gh.log" ||
  fail "with a PR already open, the step did not run gh pr edit: $(cat "$scratch/open-gh.log")"
if grep -q '^pr create' "$scratch/open-gh.log"; then
  fail 'with a PR already open, the step still ran gh pr create'
fi
grep -q 'nix flake check output' "$scratch/open-body.md" ||
  fail 'with a PR already open, the refreshed PR body lacks the new failure logs'
check_body open
pass "with a PR already open, the step keeps $fix_branch and refreshes the PR body with the new logs and the fix request"

origin=$(run_pr_step error error 1)
head_subject=$("$git_bin" --git-dir "$origin" log -1 --format=%s "$fix_branch")
[[ $head_subject == 'fix: reconcile the update' ]] ||
  fail "with the open-PR query failing, the step reset $fix_branch over its fix commit; its head is now: $head_subject"
if grep -Eq '^pr (create|edit)' "$scratch/error-gh.log"; then
  fail "with the open-PR query failing, the step still created or edited a PR: $(cat "$scratch/error-gh.log")"
fi
pass "with the open-PR query failing, the step exits non-zero and leaves $fix_branch and the PR alone"

cond=$(jq -r '.if // empty' <<<"$pr_step")
want_cond="steps.update.outputs.changed == 'true' && steps.verify.outputs.status == 'failure'"
[[ $cond == "$want_cond" ]] ||
  fail "the reconciliation PR step's if: is '$cond', not '$want_cond'"
pass 'the reconciliation PR step gates on exactly a changed, failing update'

# --- auto-merge & catalog keys ----------------------------------------------

all_step_runs=$(jq -r '.steps[].run // empty' <<<"$job")
if grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' <<<"$all_step_runs"; then
  fail 'a step runs gh pr merge, which would merge an unverified fix into main'
fi
pass 'no step runs gh pr merge'

for key in SYNTHETIC_API_KEY OPENROUTER_API_KEY; do
  if grep -q "$key" "$workflow"; then
    fail "$key appears in $workflow; model-catalogs.yml owns the catalog snapshots"
  fi
done
pass 'neither catalog key appears in this workflow'

# --- schedule ---------------------------------------------------------------

[[ $(jq '.on.schedule | length' <<<"$wf_json") == 1 ]] ||
  fail "expected one cron schedule in $workflow"
crons=$(jq -r '.on.schedule[0].cron // empty' <<<"$wf_json")
[[ -n $crons ]] || fail "could not find a cron schedule in $workflow"
read -r minutes hours dom month dow extra <<<"$crons"
[[ -z $extra && $hours == '*' && $dom == '*' && $month == '*' && $dow == '*' ]] ||
  fail "the cron does not run every hour of every day: $crons"
IFS=, read -r -a minute_list <<<"$minutes"
for minute in "${minute_list[@]}"; do
  if [[ ! $minute =~ ^[0-9]+$ ]] || ((10#$minute > 59)); then
    fail "cron minute '$minute' is not a single minute, so it may include :00: $crons"
  fi
  ((10#$minute != 0)) || fail "the cron fires at minute 0: $crons"
done
((${#minute_list[@]} == 2)) || fail "the cron fires ${#minute_list[@]} times an hour, not twice: $crons"
first_minute=$((10#${minute_list[0]}))
second_minute=$((10#${minute_list[1]}))
((first_minute != second_minute)) || fail "the cron repeats the same minute: $crons"
minute_gap=$(( (second_minute - first_minute + 60) % 60 ))
((minute_gap == 30)) || fail "the cron minutes are not 30 minutes apart: $crons"
pass "the cron fires every 30 minutes, never on the hour ($crons)"

# --- Update step (full script execution) ------------------------------------

update_script=$(step_run 'Update flake inputs, agent plugins, and packages')
[[ -n $update_script ]] || fail "could not find the update step's run block in $workflow"

# run_update_step <name> [env-assignments...]: runs the full update step script
# against an argument-checking `nix` stub.
run_update_step() {
  local name=$1 origin clone status=0
  shift
  read -r origin clone <<<"$(setup_clone "$name")"
  mkdir -p "$scratch/$name-bin"
  cat >"$scratch/$name-bin/nix" <<EOF
#!$BASH
set -euo pipefail
printf '%s\n' "\$*" >>"$scratch/$name-nix.log"
case "\$*" in
  "flake update")
    exit 0
    ;;
  "run .#agent-plugin-release -- --source EveryInc/compound-engineering-plugin --tag-prefix compound-engineering-")
    printf '%s\n' "\${RESOLVED_TAG:-compound-engineering-v2.68.0}"
    ;;
  "flake lock --update-input compound-engineering-plugin")
    jq --arg rev "\${LOCKED_REV:-2222222222222222222222222222222222222222}" \
      '.nodes["compound-engineering-plugin"].locked.rev = \$rev' flake.lock >flake.lock.tmp
    mv flake.lock.tmp flake.lock
    ;;
  "run .#claude-desktop-release -- --output packages/claude-desktop-version.json")
    printf '{"version": "1.1.0"}\n' >packages/claude-desktop-version.json
    ;;
  "run .#claude-code-release -- --output packages/claude-code-manifest.json")
    printf '{"version": "2.1.0"}\n' >packages/claude-code-manifest.json
    ;;
  "run .#android-sdk-release -- --output packages/android-sdk-repo.json")
    printf '{"latest": {"cmdline-tools": "20.0", "platform-tools": "36.0.0"}}\n' >packages/android-sdk-repo.json
    ;;
  "run .#mise-release -- --output packages/mise-release.json")
    printf '{"version": "2026.10.5"}\n' >packages/mise-release.json
    ;;
  "run .#chatgpt-release -- --output packages/chatgpt-version.json")
    if [[ " \${FAIL_SOFT:-} " == *" chatgpt "* ]]; then
      printf '{"version": "partial' >packages/chatgpt-version.json
      echo "chatgpt-release: feed failure" >&2
      exit 1
    fi
    printf '{"version": "1.2.0"}\n' >packages/chatgpt-version.json
    ;;
  "run .#t3code-release -- --output packages/t3code-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" t3code "* ]]; then
      printf '{"version": "partial' >packages/t3code-release.json
      echo "release 0.0.47-nightly has no digest for linux-x64" >&2
      exit 1
    fi
    printf '{"version": "0.0.47-nightly.20261005.2700"}\n' >packages/t3code-release.json
    ;;
  "run .#antigravity-cli-release -- --output packages/antigravity-cli-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" agy-cli "* ]]; then
      printf '{"version": "partial' >packages/antigravity-cli-release.json
      echo "antigravity-cli-release: manifest lacks linux-arm" >&2
      exit 1
    fi
    printf '{"version": "1.5.0", "platforms": {}}\n' >packages/antigravity-cli-release.json
    ;;
  "run .#antigravity-acp-release -- --output packages/antigravity-acp-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" agy-acp "* ]]; then
      printf '{"version": "partial' >packages/antigravity-acp-release.json
      echo "antigravity-acp-release: probe returned 500" >&2
      exit 1
    fi
    printf '{"version": "1.5.1", "platforms": {}}\n' >packages/antigravity-acp-release.json
    ;;
  "run .#wifiman-desktop-release -- --output packages/wifiman-desktop-version.json")
    if [[ " \${FAIL_SOFT:-} " == *" wifiman "* ]]; then
      printf '{"version": "partial' >packages/wifiman-desktop-version.json
      echo "wifiman-desktop-release: API failure" >&2
      exit 1
    fi
    printf '{"version": "1.1.0"}\n' >packages/wifiman-desktop-version.json
    ;;
  "run .#omp-release -- --output packages/omp-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" omp "* ]]; then
      printf '{"version": "partial' >packages/omp-release.json
      echo "omp-release: release v1.5.0 has no omp-linux-arm64" >&2
      exit 1
    fi
    printf '{"version": "1.5.0", "platforms": {}}\n' >packages/omp-release.json
    ;;
  "run .#npm-release -- --package acpx --output packages/acpx-release.json --lock packages/acpx/package-lock.json")
    echo "acpx" >>"$clone/npm-calls.log"
    if [[ " \${FAIL_SOFT:-} " == *" acpx "* ]]; then
      printf '{"version": "partial' >packages/acpx-release.json
      printf 'partial' >packages/acpx/package-lock.json
      echo "npm-release: npm could not write a lock file" >&2
      exit 1
    fi
    printf '{"version": "9.9.9"}\n' >packages/acpx-release.json
    printf '{"lockfileVersion": 3, "name": "acpx", "new": true}\n' >packages/acpx/package-lock.json
    ;;
  "run .#npm-release -- --package @anthropic-ai/claude-agent-sdk --output packages/claude-agent-sdk-release.json --lock packages/claude-agent-sdk/package-lock.json")
    echo "claude-agent-sdk" >>"$clone/npm-calls.log"
    if [[ " \${FAIL_SOFT:-} " == *" claude-agent-sdk "* ]]; then
      printf '{"version": "partial' >packages/claude-agent-sdk-release.json
      printf 'partial' >packages/claude-agent-sdk/package-lock.json
      echo "npm-release: npm could not write a lock file" >&2
      exit 1
    fi
    printf '{"version": "9.9.9"}\n' >packages/claude-agent-sdk-release.json
    printf '{"lockfileVersion": 3, "name": "claude-agent-sdk", "new": true}\n' >packages/claude-agent-sdk/package-lock.json
    ;;
  "run .#codex-release -- --output packages/codex-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" codex "* ]]; then
      printf '{"version": "partial' >packages/codex-release.json
      echo "codex-release: missing darwin asset" >&2
      exit 1
    fi
    printf '{"version": "0.51.0"}\n' >packages/codex-release.json
    ;;
  "run .#grok-build-release -- --output packages/grok-build-release.json")
    if [[ " \${FAIL_SOFT:-} " == *" grok "* ]]; then
      printf '{"version": "partial' >packages/grok-build-release.json
      echo "grok-build-release: 1.0.71 is not published for aarch64-darwin" >&2
      exit 1
    fi
    printf '{"version": "1.0.71", "platforms": {}}\n' >packages/grok-build-release.json
    ;;
  *)
    echo "unexpected nix invocation: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$scratch/$name-bin/nix"
  : >"$scratch/$name-output"
  (
    cd "$clone"
    env "$@" PATH="$scratch/$name-bin:$PATH" GITHUB_OUTPUT="$scratch/$name-output" \
      bash -e -c "$update_script"
  ) >"$scratch/$name-step.log" 2>&1 || status=$?
  printf '%s %s\n' "$status" "$clone"
}

read -r status clone <<<"$(run_update_step update-all)"
((status == 0)) || fail "full update step failed: $(cat "$scratch/update-all-step.log")"
grep -qx 'changed=true' "$scratch/update-all-output" ||
  fail "update step did not record changed=true: $(cat "$scratch/update-all-output")"
if grep -q '^::warning' "$scratch/update-all-step.log"; then
  fail "succeeding update step emitted a warning: $(cat "$scratch/update-all-step.log")"
fi
grep -q 'compound-engineering-plugin/compound-engineering-v2.68.0' "$clone/flake.nix" ||
  fail "update step did not update compound-engineering tag in flake.nix"
grep -q 'tag = "compound-engineering-v2.68.0";' "$clone/home/h82/agents/agent-plugin-pins.nix" ||
  fail "update step did not update tag in home/h82/agents/agent-plugin-pins.nix"
grep -q 'expectedRev = "2222222222222222222222222222222222222222";' "$clone/home/h82/agents/agent-plugin-pins.nix" ||
  fail "update step did not update expectedRev in home/h82/agents/agent-plugin-pins.nix"
grep -q '0.0.47-nightly.20261005.2700' "$clone/packages/t3code-release.json" ||
  fail "update step did not update packages/t3code-release.json"
grep -q '"1.5.0"' "$clone/packages/omp-release.json" ||
  fail "update step did not update packages/omp-release.json"
grep -q '"1.0.71"' "$clone/packages/grok-build-release.json" ||
  fail "update step did not update packages/grok-build-release.json"
grep -q '"1.5.0"' "$clone/packages/antigravity-cli-release.json" ||
  fail "update step did not update packages/antigravity-cli-release.json"
grep -q '"1.5.1"' "$clone/packages/antigravity-acp-release.json" ||
  fail "update step did not update packages/antigravity-acp-release.json"
grep -q '"9.9.9"' "$clone/packages/acpx-release.json" &&
  grep -q '"new": true' "$clone/packages/acpx/package-lock.json" ||
  fail "update step did not update acpx pin and lock file"
grep -q '"9.9.9"' "$clone/packages/claude-agent-sdk-release.json" &&
  grep -q '"new": true' "$clone/packages/claude-agent-sdk/package-lock.json" ||
  fail "update step did not update the claude-agent-sdk pin and lock file"
[[ $(paste -sd ' ' "$clone/npm-calls.log") == "acpx claude-agent-sdk" ]] ||
  fail "npm-release did not run for acpx and claude-agent-sdk, in that order"
pass 'the update step runs flake update, compound-engineering-plugin pin/lock update, and all release updaters'

read -r status clone <<<"$(run_update_step update-soft-fail "FAIL_SOFT=chatgpt t3code agy-cli wifiman omp acpx claude-agent-sdk codex grok agy-acp")"
((status == 0)) || fail "soft-failing updaters aborted the update step: $(cat "$scratch/update-soft-fail-step.log")"
for title in "ChatGPT update skipped" "T3 Code update skipped" "WiFiman Desktop update skipped" "OMP update skipped" "acpx update skipped" "claude-agent-sdk update skipped" "Codex update skipped" "Grok Build update skipped" "Antigravity CLI update skipped" "Antigravity ACP runtime update skipped"; do
  grep -q "^::warning title=$title::" "$scratch/update-soft-fail-step.log" ||
    fail "missing warning for '$title': $(cat "$scratch/update-soft-fail-step.log")"
done
[[ -z $("$git_bin" -C "$clone" status --porcelain \
  packages/chatgpt-version.json \
  packages/t3code-release.json \
  packages/wifiman-desktop-version.json \
  packages/omp-release.json \
  packages/acpx-release.json \
  packages/acpx/package-lock.json \
  packages/claude-agent-sdk-release.json \
  packages/claude-agent-sdk/package-lock.json \
  packages/codex-release.json \
  packages/grok-build-release.json \
  packages/antigravity-cli-release.json \
  packages/antigravity-acp-release.json) ]] ||
  fail "soft-failing updaters left partial changes in their pin or lock files"
pass 'soft-failing updaters (chatgpt, t3code, antigravity-cli, wifiman, omp, acpx, claude-agent-sdk, codex, grok-build, antigravity-acp) warn, restore their files, and let the step continue'

read -r status clone <<<"$(run_update_step update-acp-fail "FAIL_SOFT=agy-acp")"
((status == 0)) || fail "a failing antigravity-acp-release aborted the update step: $(cat "$scratch/update-acp-fail-step.log")"
grep -q '0.0.47-nightly.20261005.2700' "$clone/packages/t3code-release.json" ||
  fail "a failing antigravity-acp-release reverted the T3 Code bump in packages/t3code-release.json"
pass 'a failing antigravity-acp-release keeps the T3 Code bump'

read -r status _ <<<"$(run_update_step update-bad-rev "LOCKED_REV=null")"
((status != 0)) || fail "update step accepted a non-hex locked revision for compound-engineering-plugin"
grep -q 'flake.lock recorded no usable revision' "$scratch/update-bad-rev-step.log" ||
  fail "update step did not report unusable flake.lock revision: $(cat "$scratch/update-bad-rev-step.log")"
pass 'the update step rejects an unusable locked revision for compound-engineering-plugin'

# --- Verify updates step (consolidated from update-dependencies-verify-status) -

verify_step=$(step_by_name 'Verify updates') ||
  fail "could not find the Verify updates step in $workflow"
[[ $(jq -r '.if // empty' <<<"$verify_step") == "steps.update.outputs.changed == 'true'" ]] ||
  fail "the Verify updates step's if: does not gate on steps.update.outputs.changed == 'true'"
verify_script=$(jq -r '.run // empty' <<<"$verify_step")
[[ -n $verify_script ]] || fail "could not find the Verify updates step's run block in $workflow"

run_verify_step() {
  local failing=$1 dir=$scratch/verify-$1
  mkdir -p "$dir/bin"
  cat >"$dir/bin/nix" <<EOF
#!$BASH
echo "stub nix \$*"
if [[ \$1 == "$failing" ]]; then
  echo "stub nix \$1 failed"
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/bin/nix"
  : >"$dir/output"
  (
    cd "$dir"
    PATH=$dir/bin:$PATH GITHUB_OUTPUT=$dir/output GITHUB_STEP_SUMMARY=$dir/summary \
      bash -e -c "$verify_script" >/dev/null 2>&1
  ) || fail "the Verify updates step itself exited non-zero with $failing failing"
  grep -E '^status=' "$dir/output" || true
}

for failing in fmt flake build; do
  vstatus=$(run_verify_step "$failing")
  [[ $vstatus == "status=failure" ]] ||
    fail "a failing nix $failing reported '$vstatus', so the push step would land the update on main"
  pass "a failing nix $failing reports status=failure"
done

vstatus=$(run_verify_step none)
[[ $vstatus == "status=success" ]] || fail "all commands succeeding reported '$vstatus'"
pass 'all verification commands succeeding reports status=success'

grep -q 'stub nix build failed' "$scratch/verify-build/vm-check.log" 2>/dev/null ||
  fail 'the VM build log is not in vm-check.log'
if grep -q 'stub nix build' "$scratch/verify-build/check.log"; then
  fail 'the VM build log was written into check.log, burying the nix flake check tail'
fi
pass 'the VM build log goes to vm-check.log, not check.log'

# --- Push verified updates step (per-pin commits & push-order scenarios) ----

push_step=$(step_by_name 'Push verified updates directly to main') ||
  fail "could not find the push step in $workflow"
want_push_cond="steps.update.outputs.changed == 'true' && steps.verify.outputs.status == 'success'"
[[ $(jq -r '.if // empty' <<<"$push_step") == "$want_push_cond" ]] ||
  fail "the push step's if: does not match '$want_push_cond'"
push_script=$(jq -r '.run // empty' <<<"$push_step")
[[ -n $push_script ]] || fail "could not find the push step's run block in $workflow"

read -r origin clone <<<"$(setup_clone pin-bumps)"
base_sha=$("$git_bin" -C "$clone" rev-parse HEAD)
new_t3_version=0.0.46-nightly.20261004.2644
printf '{"version": "%s"}\n' "$new_t3_version" >"$clone/packages/t3code-release.json"
printf '{"version": "1.5.0", "platforms": {}}\n' >"$clone/packages/omp-release.json"
printf '{"version": "0.21.0"}\n' >"$clone/packages/acpx-release.json"
printf '{"version": "1.0.71", "platforms": {}}\n' >"$clone/packages/grok-build-release.json"
printf '{"version": "1.5.0", "platforms": {}}\n' >"$clone/packages/antigravity-cli-release.json"
printf '{"version": "1.5.1", "platforms": {}}\n' >"$clone/packages/antigravity-acp-release.json"
printf '{"lockfileVersion": 3, "name": "acpx", "new": true}\n' >"$clone/packages/acpx/package-lock.json"
sed -i 's/compound-engineering-v2.67.0/compound-engineering-v2.68.0/' \
  "$clone/flake.nix" "$clone/home/h82/agents/agent-plugin-pins.nix"
sed -i 's/1111111111111111111111111111111111111111/2222222222222222222222222222222222222222/' \
  "$clone/flake.lock" "$clone/home/h82/agents/agent-plugin-pins.nix"
(cd "$clone" && bash -e -c "$push_script") >"$scratch/pin-bumps-step.log" 2>&1 ||
  fail "the push step failed on the per-pin updates: $(tail -n 5 "$scratch/pin-bumps-step.log")"
commits=$("$git_bin" --git-dir "$origin" log --reverse --format='%H %s' "$base_sha..main")
[[ $(wc -l <<<"$commits") == 7 ]] || fail "expected 7 per-pin commits, found: $commits"
for expected in \
  'chore(packages): bump omp to 1.5.0|packages/omp-release.json' \
  'chore(packages): bump grok-build to 1.0.71|packages/grok-build-release.json' \
  'chore(packages): bump acpx to 0.21.0|packages/acpx-release.json packages/acpx/package-lock.json' \
  "chore(packages): bump t3code to $new_t3_version|packages/t3code-release.json" \
  'chore(packages): bump antigravity-cli to 1.5.0|packages/antigravity-cli-release.json' \
  'chore(packages): bump antigravity-acp to 1.5.1|packages/antigravity-acp-release.json' \
  'chore(agents): bump compound-engineering to compound-engineering-v2.68.0|flake.lock flake.nix home/h82/agents/agent-plugin-pins.nix'; do
  subject=${expected%%|*} want=${expected#*|}
  sha=$(awk -v s="$subject" '{ sha = $1; sub(/^[^ ]+ /, "") } $0 == s { print sha }' <<<"$commits")
  [[ -n $sha ]] || fail "no commit '$subject' among: $commits"
  files=$("$git_bin" --git-dir "$origin" show --format= --name-only "$sha" | sort | paste -sd ' ')
  [[ $files == "$want" ]] || fail "'$subject' carries $files, want $want"
done
pass 'the t3code, antigravity-cli, antigravity-acp, omp, acpx, grok-build, and compound-engineering changes each land as their own commit with only their files'

# --- origin/main unchanged: dirty-tree commit-before-rebase & .gitignore logs
read -r origin clone <<<"$(setup_clone same)"
printf 'changed\n' >>"$clone/tracked.txt"
printf 'nix fmt output\n' >"$clone/fmt.log"
printf 'nix flake check output\n' >"$clone/check.log"
printf 'nix build vmChecks output\n' >"$clone/vm-check.log"
(cd "$clone" && bash -c "$push_script") >"$scratch/same-step.log" 2>&1 ||
  fail 'the push step failed against an unchanged origin/main (dirty-tree rebase regression)'
pushed=$("$git_bin" --git-dir "$origin" log -1 --format=%s main)
[[ $pushed == "chore(deps): update dependencies" ]] ||
  fail "origin/main does not carry the pushed commit: $pushed"
tracked=$("$git_bin" --git-dir "$origin" ls-tree -r --name-only main)
[[ $tracked != *"fmt.log"* && $tracked != *"check.log"* && $tracked != *"vm-check.log"* ]] ||
  fail "verification logs were committed to main: $tracked"
pass "succeeds against unchanged origin/main and never commits the verify step's fmt.log/check.log/vm-check.log"

# --- origin/main advanced with an unrelated commit: must rebase and push both
read -r origin clone <<<"$(setup_clone diverged)"
other=$scratch/diverged-other
"$git_bin" clone -q "$origin" "$other"
"$git_bin" -C "$other" config user.email o@example.invalid
"$git_bin" -C "$other" config user.name Other
printf 'concurrent\n' >"$other/other.txt"
"$git_bin" -C "$other" add other.txt
"$git_bin" -C "$other" commit -qm 'concurrent commit'
"$git_bin" -C "$other" push -q origin main

printf 'changed\n' >>"$clone/tracked.txt"
(cd "$clone" && bash -c "$push_script") >"$scratch/diverged-step.log" 2>&1 ||
  fail 'the push step failed to rebase onto a diverged origin/main'
log=$("$git_bin" --git-dir "$origin" log --format=%s main)
[[ $log == *"chore(deps): update dependencies"* ]] ||
  fail "origin/main is missing the rebased commit: $log"
[[ $log == *"concurrent commit"* ]] ||
  fail "origin/main lost the concurrent commit it should have rebased onto: $log"
pass 'rebases onto a diverged origin/main and pushes both commits'
