#!/usr/bin/env bash
#
# Check interface:
#
#   bash tests/synthetic-models-reconcile.sh <synthetic-models-workflow> \
#     <watch-script> <catalog-snapshot> <model-source-json>
#
# Runs the "Open, update, or close the reconcile issue" step's literal
# script with a stub `gh`, which logs every call and answers the open-issue
# list and the issue view from fixtures, and a stub `nix`, which runs the
# real watch script for `nix run .#synthetic-models-watch -- ...`. Every
# result.json, issue body, and open issue body comes from that script, run
# against the model source and catalogs derived from the snapshot.
#
# - Drift with no open issue creates one, with the result's title and body.
# - The same fingerprint and body digest write nothing.
# - A new fingerprint edits the issue once and comments once.
# - The same fingerprint with a new body digest edits it once, silently.
# - Clean with an open issue comments the commit and closes it; clean with
#   none writes nothing; any other status exits non-zero.
# - With several open issues, the oldest is kept and every other one gets a
#   comment naming it and is closed.
# - A failed comparison exits non-zero and comments once per failure streak
#   on an open issue, and writes nothing when none is open. The first run
#   that succeeds after it says the catalog is reachable again.
# - The workflow's permissions are exactly contents: read and issues: write,
#   the issue step runs after a failed comparison, and only the comparison
#   step sees SYNTHETIC_API_KEY.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'usage: %s WORKFLOW WATCH_SCRIPT CATALOG SOURCE_JSON\n' "${0##*/}" >&2
  exit 2
fi
workflow=$1 watch_script=$2 catalog=$3 source_json=$4
for file in "$workflow" "$watch_script" "$catalog" "$source_json"; do
  [[ -f $file ]] || { printf 'missing %s\n' "$file" >&2; exit 2; }
done

fail() { printf 'synthetic-models-reconcile: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'synthetic-models-reconcile: ok - %s\n' "$*"; }

python=$(command -v python3) || fail 'python3 is required'
command -v jq >/dev/null || fail 'jq is required'

step_name='Open, update, or close the reconcile issue'

# step_run <name>: the dedented `run: |` block of the named step.
step_run() {
  awk -v step="- name: $1" '
    found == 0 && index($0, step) > 0 { found = 1; next }
    found == 1 && capturing == 0 && $0 ~ /^[[:space:]]*run: \|[[:space:]]*$/ { capturing = 1; next }
    capturing == 1 {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      line = $0
      sub(/^[[:space:]]*/, "", line)
      lead = length($0) - length(line)
      if (indent < 0) { indent = lead }
      if (lead < indent) { exit }
      print substr($0, indent + 1)
      next
    }
  ' indent=-1 "$workflow"
}

# step_block <name>: every line of the named step, up to the next step.
step_block() {
  awk -v step="- name: $1" '
    found == 0 && index($0, step) > 0 {
      found = 1
      line = $0
      sub(/^[[:space:]]*/, "", line)
      indent = length($0) - length(line)
      print
      next
    }
    found == 1 {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      lead = length($0) - length(line)
      if (line != "" && lead <= indent) { exit }
      print
    }
  ' "$workflow"
}

# --- workflow shape ----------------------------------------------------------

permissions=$(awk '
  /^permissions:/ { inside = 1; next }
  inside && /^[^[:space:]]/ { exit }
  inside && NF { sub(/^[[:space:]]+/, ""); print }
' "$workflow")
if [[ $permissions != $'contents: read\nissues: write' ]]; then
  fail "the workflow's permissions are not exactly contents: read and issues: write: $permissions"
fi
if [[ $(grep -c 'permissions:' "$workflow") -ne 1 ]]; then
  fail 'the workflow declares permissions outside its top level'
fi
pass 'permissions are exactly contents: read and issues: write'

compare_block=$(step_block "Compare with Synthetic's catalog")
issue_block=$(step_block "$step_name")
[[ -n $compare_block && -n $issue_block ]] || fail "could not find the watch steps in $workflow"
grep -Eq '^[[:space:]]*id: compare[[:space:]]*$' <<<"$compare_block" ||
  fail 'the comparison step has no id: compare'
grep -Fq "if: \${{ !cancelled() && (steps.compare.outcome == 'success' || steps.compare.outcome == 'failure') }}" \
  <<<"$issue_block" || fail 'the issue step does not run after both outcomes of the comparison'
grep -Fq 'COMPARE_OUTCOME: ${{ steps.compare.outcome }}' <<<"$issue_block" ||
  fail 'the issue step does not receive the comparison outcome'
grep -Eq '^[[:space:]]*LABEL: model-reconcile[[:space:]]*$' <<<"$issue_block" ||
  fail 'the issue step does not use the model-reconcile label'
if [[ $(grep -c 'SYNTHETIC_API_KEY' "$workflow") -ne 1 ]] ||
  ! grep -Fq 'SYNTHETIC_API_KEY: ${{ secrets.SYNTHETIC_API_KEY }}' <<<"$compare_block"; then
  fail 'SYNTHETIC_API_KEY reaches a step other than the comparison'
fi
pass 'the issue step runs after a failed comparison, and only the comparison sees the key'

script=$(step_run "$step_name")
[[ -n $script ]] || fail "could not find the issue step's run block in $workflow"
# The script owns the markers; the step reads them only through --issue-state.
if grep -Eq 'synthetic-models-watch (fingerprint|body|notice)|sha256|capture\(' <<<"$script"; then
  fail 'the issue step parses the watch markers itself instead of through --issue-state'
fi
grep -Fq 'watch --issue-state' <<<"$script" || fail 'the issue step does not read the issue through --issue-state'
pass 'the issue step reads the markers only through the script'

# --- fixtures from the real script --------------------------------------------

scratch=$(mktemp -d "${TMPDIR:-/tmp}/synthetic-models-reconcile.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

flash='hf:zai-org/GLM-5.3-Flash'
glm='hf:zai-org/GLM-5.3'

# watch_run <name> <jq-filter>: runs the real script on the snapshot as the
# filter rewrites it, into $scratch/<name>.json and <name>.md.
watch_run() {
  jq "$2" "$catalog" >"$scratch/$1-catalog.json"
  "$python" "$watch_script" --source-json "$source_json" --catalog "$scratch/$1-catalog.json" \
    --detected-at 2026-10-21T09:00:00Z --result "$scratch/$1.json" --issue-body "$scratch/$1.md" ||
    fail "the watch script failed on the $1 catalog"
}
drop() { printf 'del(.data[] | select(.id == "%s" and (has("alias_of") | not)))' "$1"; }
glm_efforts() {
  printf '(.data[] | select(.id == "%s") | .reasoning_parameters.efforts) = %s' "$glm" "$1"
}

watch_run flash "$(drop "$flash")"
watch_run flash-glm "$(drop "$flash") | $(drop "$glm")"
watch_run clean '.'
watch_run glm-low-high "$(glm_efforts '["low","high"]')"
watch_run glm-high "$(glm_efforts '["high"]')"

[[ $(jq -r .status "$scratch/flash.json") == drift ]] || fail 'the flash fixture is not drift'
[[ $(jq -r .status "$scratch/clean.json") == clean ]] || fail 'the snapshot fixture is not clean'
[[ $(jq -r .fingerprint "$scratch/flash.json") != $(jq -r .fingerprint "$scratch/flash-glm.json") ]] ||
  fail 'the two drift fixtures share a fingerprint'
[[ $(jq -r .fingerprint "$scratch/glm-low-high.json") == $(jq -r .fingerprint "$scratch/glm-high.json") ]] ||
  fail 'the effort fixtures differ in fingerprint'
[[ $(jq -r .bodyDigest "$scratch/glm-low-high.json") != $(jq -r .bodyDigest "$scratch/glm-high.json") ]] ||
  fail 'the effort fixtures share a body digest'
printf '%s\n' "$(jq '.status = "unknown"' "$scratch/clean.json")" >"$scratch/unknown.json"

notice() { "$python" "$watch_script" --notice "$1"; }

# --- the step ------------------------------------------------------------------

mkdir -p "$scratch/bin"
cat >"$scratch/bin/gh" <<EOF
#!$BASH
set -euo pipefail
n=\$(( \$(wc -l <"\$STUB_LOG") + 1 ))
printf '%s\n' "\$*" >>"\$STUB_LOG"
prev=
limit=30
for arg in "\$@"; do
  if [[ \$prev == --body-file ]]; then cp "\$arg" "\$STUB_DIR/body-\$n.md"; fi
  if [[ \$prev == --limit ]]; then limit=\$arg; fi
  prev=\$arg
done
# gh lists the newest issues first, up to --limit (default 30).
if [[ \$1 == issue && \$2 == list ]]; then
  jq --argjson limit "\$limit" 'sort_by(-.number) | .[:\$limit]' "\$STUB_OPEN"
  exit 0
fi
if [[ \$1 == issue && \$2 == view ]]; then cat "\$STUB_DIR/view-\$3.json"; exit 0; fi
exit 0
EOF
cat >"$scratch/bin/nix" <<EOF
#!$BASH
if [[ \$1 != run || \$2 != .#synthetic-models-watch || \$3 != -- ]]; then
  echo "unexpected nix call: \$*" >&2
  exit 97
fi
shift 3
exec "$python" "$watch_script" "\$@"
EOF
chmod +x "$scratch/bin/gh" "$scratch/bin/nix"

# run_step <case> <outcome> <result-name|-> <open-numbers-json> [<number> <view-json>]...
# Runs the step for one case; sets $status and $log, and the bodies the
# stub received sit in $dir/body-<call>.md.
run_step() {
  local name=$1 outcome=$2 result=$3 open=$4
  shift 4
  dir=$scratch/case-$name
  mkdir -p "$dir/runner"
  log=$dir/gh.log
  : >"$log"
  jq 'map({number: .})' <<<"$open" >"$dir/open.json"
  while (($#)); do
    cp "$2" "$dir/view-$1.json"
    shift 2
  done
  if [[ $result != - ]]; then
    cp "$scratch/$result.json" "$dir/runner/watch.json"
    if [[ -f $scratch/$result.md ]]; then cp "$scratch/$result.md" "$dir/runner/issue.md"; fi
  fi
  status=0
  PATH=$scratch/bin:$PATH STUB_LOG=$log STUB_DIR=$dir STUB_OPEN=$dir/open.json \
    RUNNER_TEMP=$dir/runner GITHUB_REPOSITORY=example/nix-config GITHUB_SHA=0123abcd \
    GH_TOKEN=fake-token LABEL=model-reconcile COMPARE_OUTCOME=$outcome \
    bash -c "$script" >"$dir/step.log" 2>&1 || status=$?
}

# view <name> <body-file> <comment-file>...: a `gh issue view` answer.
view() {
  local out=$scratch/view-$1.json body=$2
  shift 2
  local comments='[]'
  for c in "$@"; do comments=$(jq --rawfile b "$c" '. + [{author: {login: "github-actions"}, body: $b}]' <<<"$comments"); done
  jq -n --rawfile b "$body" --argjson c "$comments" '{body: $b, comments: $c}' >"$out"
  printf '%s\n' "$out"
}

expect_blind_message() {
  grep -Fq "the comparison with Synthetic's catalog failed" "$dir/step.log" ||
    fail "a failed comparison exited for another reason: $(tail -n 5 "$dir/step.log")"
}
writes() { grep -Ev '^issue (list|view) ' "$log" || true; }
expect_ok() { ((status == 0)) || fail "$1: the step exited $status: $(tail -n 5 "$dir/step.log")"; }
expect_writes() {
  local want=$1 what=$2 got
  got=$(writes)
  [[ $got == "$want" ]] || fail "$what: expected writes [$want], got [$got]"
}

notice unreachable >"$scratch/unreachable.md"
notice reachable >"$scratch/reachable.md"
printf 'a person comments\n' >"$scratch/person.md"

# Drift with no open issue: one label and one create.
run_step create success flash '[]'
expect_ok 'drift with no open issue'
title=$(jq -r .title "$scratch/flash.json")
expect_writes "label create model-reconcile --repo example/nix-config --force --color B60205 --description Synthetic model drift for home/h82/agents/synthetic-models.nix
issue create --repo example/nix-config --label model-reconcile --title $title --body-file $dir/runner/issue.md" \
  'drift with no open issue'
cmp -s "$dir/body-3.md" "$scratch/flash.md" || fail 'the created issue does not carry the script body'
pass 'drift with no open issue creates one issue'

# The same drift: nothing.
run_step same success flash '[4]' 4 "$(view same "$scratch/flash.md")"
expect_ok 'the same drift'
grep -Fxq 'issue view 4 --repo example/nix-config --json body,comments' "$log" || fail 'the open issue was not read'
expect_writes '' 'the same drift'
pass 'the same fingerprint and body write nothing'

# A new fingerprint: one edit and one comment.
run_step changed success flash-glm '[4]' 4 "$(view changed "$scratch/flash.md")"
expect_ok 'a new fingerprint'
title=$(jq -r .title "$scratch/flash-glm.json")
expect_writes "issue edit 4 --repo example/nix-config --title $title --body-file $dir/runner/issue.md
issue comment 4 --repo example/nix-config --body-file $dir/runner/changed.md" 'a new fingerprint'
cmp -s "$dir/body-3.md" "$scratch/flash-glm.md" || fail 'the edit does not carry the new body'
grep -Fxq "$(head -n 1 "$scratch/flash-glm.md")" "$dir/body-4.md" || fail 'the change comment lacks the first line'
pass 'a new fingerprint edits once and comments once'

# The same fingerprint, a new body: one silent edit.
run_step refreshed success glm-high '[4]' 4 "$(view refreshed "$scratch/glm-low-high.md")"
expect_ok 'a new body digest'
title=$(jq -r .title "$scratch/glm-high.json")
expect_writes "issue edit 4 --repo example/nix-config --title $title --body-file $dir/runner/issue.md" 'a new body digest'
pass 'a new body digest with the same fingerprint edits without a comment'

# Clean with an open issue: comment the commit and close it.
run_step resolved success clean '[4]' 4 "$(view resolved "$scratch/flash.md")"
expect_ok 'clean with an open issue'
expect_writes "issue comment 4 --repo example/nix-config --body-file $dir/runner/resolved.md
issue close 4 --repo example/nix-config" 'clean with an open issue'
grep -Fq 'as of commit 0123abcd' "$dir/body-3.md" || fail 'the resolving comment lacks the commit'
pass 'clean with an open issue comments and closes it'

# Clean with none: nothing.
run_step quiet success clean '[]'
expect_ok 'clean with no issue'
expect_writes '' 'clean with no issue'
pass 'clean with no open issue writes nothing'

# Any other status: non-zero.
run_step unknown success unknown '[]'
((status != 0)) || fail 'an unknown status exited 0'
grep -Fq 'unexpected watch status: unknown' "$dir/step.log" || fail 'an unknown status failed for another reason'
pass 'an unknown status exits non-zero'

# Several open issues: keep the oldest, close the rest pointing at it.
run_step duplicates success flash '[9,3,7]' 3 "$(view duplicates "$scratch/flash.md")"
expect_ok 'several open issues'
expect_writes "issue comment 7 --repo example/nix-config --body-file $dir/runner/duplicate.md
issue close 7 --repo example/nix-config
issue comment 9 --repo example/nix-config --body-file $dir/runner/duplicate.md
issue close 9 --repo example/nix-config" 'several open issues'
grep -Fq 'duplicate of #3' "$dir/body-2.md" || fail 'the duplicate comment does not name the kept issue'
pass 'the oldest open issue is kept and the others are closed'

# A failed comparison with an open issue: one notice, non-zero.
run_step blind failure - '[4]' 4 "$(view blind "$scratch/flash.md" "$scratch/person.md")"
((status != 0)) || fail 'a failed comparison exited 0'
expect_blind_message
expect_writes "issue comment 4 --repo example/nix-config --body-file $dir/runner/notice.md" 'a failed comparison'
cmp -s "$dir/body-3.md" "$scratch/unreachable.md" || fail 'the notice is not the unreachable notice'
pass 'a failed comparison comments once on the open issue'

# Still failing: no second notice.
run_step still-blind failure - '[4]' 4 "$(view still-blind "$scratch/flash.md" "$scratch/unreachable.md" "$scratch/person.md")"
((status != 0)) || fail 'a second failed comparison exited 0'
expect_blind_message
expect_writes '' 'a second failed comparison'
pass 'a failure streak comments only once'

# A new streak after a recovery: a notice again.
run_step blind-again failure - '[4]' 4 "$(view blind-again "$scratch/flash.md" "$scratch/unreachable.md" "$scratch/reachable.md")"
((status != 0)) || fail 'a failed comparison after a recovery exited 0'
expect_blind_message
expect_writes "issue comment 4 --repo example/nix-config --body-file $dir/runner/notice.md" 'a new failure streak'
pass 'a new failure streak comments again'

# A failed comparison with no open issue: nothing, non-zero.
run_step blind-alone failure - '[]'
((status != 0)) || fail 'a failed comparison with no issue exited 0'
expect_blind_message
expect_writes '' 'a failed comparison with no issue'
pass 'a failed comparison with no open issue writes nothing'

# Recovery: the same drift after a notice says the catalog is reachable.
run_step recovered success flash '[4]' 4 "$(view recovered "$scratch/flash.md" "$scratch/unreachable.md")"
expect_ok 'a recovery'
expect_writes "issue comment 4 --repo example/nix-config --body-file $dir/runner/notice.md" 'a recovery'
cmp -s "$dir/body-3.md" "$scratch/reachable.md" || fail 'the recovery comment is not the reachable notice'
pass 'the first run after a failure streak says the catalog is reachable'
