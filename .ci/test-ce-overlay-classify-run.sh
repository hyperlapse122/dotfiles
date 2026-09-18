#!/usr/bin/env bash
set -euo pipefail

# Offline verification of .ci/ce-overlay-classify-run.sh, the record job's
# decision. Each case sets the job outcomes in the environment, runs the script
# in a scratch tree with a real bun and the real marker state machine, and checks
# the GITHUB_OUTPUT lines and the transition event it logs.
#
# The tree holds the real script and libraries, a symlink to the real packages,
# a fixture marker, and a stub `.ci/ce-overlay-lock-hold.sh` whose `resolve-latest`
# answers from the environment, so nothing reaches the network.
#
# CASES: a cancelled job records nothing; a run with nothing to rebase records
# nothing; a failed preflight (configuration with and without a usable missing
# list, and any other failure); a failed prepare per state; a failed Claude job; a
# failed publish with and without a Claude run; a class outside the closed set
# and a class carrying a newline; a manual run; the marker's own issue number; a
# third attempt that escalates; and the target fallback (a valid target never
# resolves, an invalid or prerelease target resolves, a failed or invalid
# resolution falls back to the marker's target).

root=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlay-classify-run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'test-ce-overlay-classify-run: %s\n' "$*" >&2
  exit 1
}

pass() { printf 'test-ce-overlay-classify-run: ok - %s\n' "$*"; }

for tool in bun jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

tag_marker=compound-engineering-v3.26.3
tag_new=compound-engineering-v3.26.4

tree="$scratch/tree"
mkdir -p -- "$tree/.ci" "$tree/.chezmoidata" "$scratch/tmp"
cp -Rp -- "$root/.ci/lib" "$tree/.ci/lib"
cp -p -- "$root/.ci/ce-overlay-classify-run.sh" "$tree/.ci/ce-overlay-classify-run.sh"
ln -s -- "$root/packages" "$tree/packages"
cat >"$tree/.ci/ce-overlay-lock-hold.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1-}" = resolve-latest ] || exit 64
printf 'resolve-latest\n' >>"$STUB_LOG"
[ "${STUB_LATEST_RC:-0}" = 0 ] || exit "$STUB_LATEST_RC"
printf '%s\n' "${STUB_LATEST-}"
STUB
chmod 0755 "$tree/.ci/ce-overlay-classify-run.sh" "$tree/.ci/ce-overlay-lock-hold.sh"

marker_file="$tree/.chezmoidata/ce-overlay-rebase.json"
write_marker() { # <status> <attempts> <first attempt or null> <issue or null>
  jq -n --arg target "$tag_marker" --arg status "$1" --argjson attempts "$2" --argjson first "$3" --argjson issue "$4" '
    {ceOverlayRebase: {target: $target, status: $status, attempts: $attempts, firstAttempt: $first,
      lastAttempt: null, notBefore: null, failureClass: null, missing: [], issue: $issue}}' >"$marker_file"
}
write_marker idle 0 null null

github_output="$scratch/github-output"
stub_log="$scratch/stub.log"
stdout=''
rc=0
classify() { # [VAR=value ...]: a run where every job succeeded, then the overrides
  : >"$github_output"
  : >"$stub_log"
  rc=0
  stdout=$(cd -- "$tree" && env -i PATH="$PATH" HOME="$HOME" RUNNER_TEMP="$scratch/tmp" \
    GITHUB_OUTPUT="$github_output" STUB_LOG="$stub_log" STUB_LATEST="$tag_new" \
    PF_RESULT=success PF_CLASS='' PF_MISSING='' MANUAL=false \
    PREP_RESULT=success PREP_STATE=resolved TARGET="$tag_new" \
    CLAUDE_RESULT=skipped CLAUDE_CLASS='' PUB_RESULT=success PUB_CLASS='' PUB_MISSING='' \
    "$@" .ci/ce-overlay-classify-run.sh 2>"$scratch/stderr") || rc=$?
  [[ $rc == 0 ]] || fail "the script failed with status $rc: $(<"$scratch/stderr")"
}

output_of() { sed -n "s/^$1=//p" "$github_output" | tail -n 1; }
event_of() { printf '%s\n' "$stdout" | sed -n 's/^transition event: //p' | tail -n 1; }

expect_output() { # <label> <key> <expected>
  local actual
  actual=$(output_of "$2")
  [[ $actual == "$3" ]] || fail "$1: $2 was '$actual', want '$3'"
}

expect_nothing() { # <label>: the whole output is the four decision lines
  local want
  want=$(printf 'action=none\nclass=\nmissing=\nreached=false\n')
  [[ $(<"$github_output") == "$want" ]] || fail "$1: the output was: $(<"$github_output")"
  [[ -z $(event_of) ]] || fail "$1: a transition event was logged"
  pass "$1"
}

# expect_failure <label> <class> <missing csv> <reached> <needs_issue> <target>
expect_failure() {
  local label=$1 class=$2 missing=$3 reached=$4 needs_issue=$5 target=$6 event now manual_flag='' expected
  expect_output "$label" action failure
  expect_output "$label" class "$class"
  expect_output "$label" missing "$missing"
  expect_output "$label" reached "$reached"
  expect_output "$label" needs_issue "$needs_issue"
  expect_output "$label" target "$target"
  now=$(output_of now)
  [[ $now =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "$label: now was '$now'"
  [[ ${MANUAL_EXPECTED:-false} == true ]] && manual_flag=true
  expected=$(jq -S -c -n --arg t "$target" --arg c "$class" --arg r "$reached" --arg m "$missing" --arg now "$now" --arg manual "$manual_flag" '
    {type: "failure", target: $t, failureClass: $c, reachedClaude: ($r == "true"), now: $now}
    + (if $m == "" then {} else {missing: ($m | split(","))} end)
    + (if $manual == "true" then {manualTrigger: true} else {} end)')
  event=$(event_of)
  [[ $(jq -S -c . <<<"$event") == "$expected" ]] || fail "$label: the event was $event, want $expected"
  pass "$label"
}

# --- runs that record nothing -------------------------------------------------

for job in PF_RESULT PREP_RESULT CLAUDE_RESULT PUB_RESULT; do
  classify PF_RESULT=failure PREP_RESULT=failure PREP_STATE=genuine CLAUDE_RESULT=failure PUB_RESULT=failure "$job=cancelled"
  expect_nothing "a cancelled $job records nothing even beside failures"
done
classify PF_RESULT=cancelled PF_CLASS=configuration PF_MISSING=P1
expect_nothing 'a cancelled preflight records nothing'
grep -qF 'cancelled' <<<"$stdout" || fail 'a cancelled run did not say so'
[[ ! -s $stub_log ]] || fail 'a cancelled run resolved the latest release'

classify
expect_nothing 'a run where every job succeeded records nothing'

classify PREP_STATE=current CLAUDE_RESULT=skipped PUB_RESULT=skipped
expect_nothing 'a run with nothing to rebase records nothing'

# --- preflight ----------------------------------------------------------------

classify PF_RESULT=failure PF_CLASS=configuration PF_MISSING=P1,P3 PREP_RESULT=skipped PREP_STATE='' TARGET='' PUB_RESULT=skipped
expect_failure 'a failed preflight names the missing prerequisites' configuration P1,P3 false true "$tag_new"
[[ $(<"$stub_log") == resolve-latest ]] || fail 'an empty target did not resolve the latest release once'

classify PF_RESULT=failure PF_CLASS=configuration 'PF_MISSING=P9;rm' PREP_RESULT=skipped PREP_STATE='' TARGET='' PUB_RESULT=skipped
expect_failure 'an unusable missing list is dropped' configuration '' false true "$tag_new"

classify PF_RESULT=failure PF_CLASS=outage PF_MISSING=P2 PREP_RESULT=skipped PREP_STATE='' TARGET='' PUB_RESULT=skipped
expect_failure 'a preflight failure that is not configuration is unknown and carries no missing list' unknown '' false true "$tag_new"

# --- prepare ------------------------------------------------------------------

classify PREP_RESULT=failure PREP_STATE=genuine PUB_RESULT=skipped
expect_failure 'a genuine prepare failure' genuine '' false true "$tag_new"
classify PREP_RESULT=failure PREP_STATE=unavailable PUB_RESULT=skipped
expect_failure 'an unavailable prepare is an outage' outage '' false false "$tag_new"
classify PREP_RESULT=failure PREP_STATE=unknown PUB_RESULT=skipped
expect_failure 'an unknown prepare state' unknown '' false true "$tag_new"
classify PREP_RESULT=failure PREP_STATE='' PUB_RESULT=skipped
expect_failure 'a prepare with no state' unknown '' false true "$tag_new"

# --- claude -------------------------------------------------------------------

classify PREP_STATE=claude CLAUDE_RESULT=failure CLAUDE_CLASS=quota PUB_RESULT=skipped
expect_failure 'a Claude quota failure reached Claude' quota '' true false "$tag_new"
classify PREP_STATE=claude CLAUDE_RESULT=failure CLAUDE_CLASS=outage PUB_RESULT=skipped
expect_failure 'a Claude outage reached Claude' outage '' true false "$tag_new"
classify PREP_STATE=claude CLAUDE_RESULT=failure CLAUDE_CLASS=bogus PUB_RESULT=skipped
expect_failure 'a Claude class outside the closed set is unknown' unknown '' true true "$tag_new"
classify PREP_STATE=claude CLAUDE_RESULT=failure "CLAUDE_CLASS=$(printf 'quota\nclass=none')" PUB_RESULT=skipped
expect_failure 'a Claude class carrying a newline is unknown' unknown '' true true "$tag_new"
[[ $(grep -c '^class=' "$github_output") == 1 ]] || fail 'a class carrying a newline wrote a second class line'

# --- publish ------------------------------------------------------------------

classify PUB_RESULT=failure PUB_CLASS=genuine
expect_failure 'a publish failure without a Claude run did not reach Claude' genuine '' false true "$tag_new"
classify PREP_STATE=claude CLAUDE_RESULT=success PUB_RESULT=failure PUB_CLASS=genuine
expect_failure 'a publish failure after a Claude run reached Claude' genuine '' true true "$tag_new"
classify PREP_STATE=claude CLAUDE_RESULT=success PUB_RESULT=failure PUB_CLASS=configuration PUB_MISSING=P3
expect_failure 'a publish failure keeps its missing prerequisite' configuration P3 true true "$tag_new"
classify PUB_RESULT=failure PUB_CLASS=outage
expect_failure 'a publish outage without a Claude run' outage '' false false "$tag_new"
classify PUB_RESULT=failure PUB_CLASS=''
expect_failure 'a publish failure with no class is unknown' unknown '' false true "$tag_new"
classify PUB_RESULT=failure PUB_CLASS=configuration PUB_MISSING=P1,P5
expect_failure 'a missing list with a prerequisite outside P1 to P4 is dropped' configuration '' false true "$tag_new"

# --- manual, marker state, escalation -----------------------------------------

classify MANUAL=true PUB_RESULT=failure PUB_CLASS=outage
MANUAL_EXPECTED=true expect_failure 'a manual run marks the event' outage '' false false "$tag_new"

first_attempt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_marker deferred 1 "\"$first_attempt\"" 42
classify PUB_RESULT=failure PUB_CLASS=outage
expect_failure 'a failure keeps the marker issue for the tracking step' outage '' false false "$tag_new"
expect_output 'the marker issue' existing_issue 42

write_marker deferred 2 "\"$first_attempt\"" null
classify PREP_STATE=claude CLAUDE_RESULT=failure CLAUDE_CLASS=outage PUB_RESULT=skipped "TARGET=$tag_marker"
expect_failure 'a third attempt at the marker target that reached Claude escalates' outage '' true true "$tag_marker"
classify PREP_STATE=claude CLAUDE_RESULT=failure CLAUDE_CLASS=outage PUB_RESULT=skipped
expect_failure 'a newer target restarts the count, so the same failure defers' outage '' true false "$tag_new"
write_marker idle 0 null null

# --- target fallback ----------------------------------------------------------

classify PUB_RESULT=failure PUB_CLASS=genuine
[[ ! -s $stub_log ]] || fail 'a valid target resolved the latest release'
pass 'a valid target never resolves the latest release'

classify PUB_RESULT=failure PUB_CLASS=genuine TARGET=latest
expect_failure 'a target that is not a release tag resolves the latest release' genuine '' false true "$tag_new"
[[ $(<"$stub_log") == resolve-latest ]] || fail 'an invalid target did not resolve the latest release'

classify PUB_RESULT=failure PUB_CLASS=genuine TARGET=compound-engineering-v3.26.4-rc.1 STUB_LATEST=compound-engineering-v3.27.0
expect_failure 'a prerelease target resolves the latest release' genuine '' false true compound-engineering-v3.27.0

classify PUB_RESULT=failure PUB_CLASS=genuine TARGET='' STUB_LATEST_RC=2
expect_failure 'a failed resolution falls back to the marker target' genuine '' false true "$tag_marker"

classify PUB_RESULT=failure PUB_CLASS=genuine TARGET='' STUB_LATEST=latest
expect_failure 'an invalid resolution falls back to the marker target' genuine '' false true "$tag_marker"

classify PUB_RESULT=failure PUB_CLASS=genuine TARGET='' STUB_LATEST=''
expect_failure 'an empty resolution falls back to the marker target' genuine '' false true "$tag_marker"

printf 'test-ce-overlay-classify-run: all cases passed\n'
