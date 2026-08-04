#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

fixtures=.ci/fixtures/cutover-gates
evaluator=.ci/evaluate-cutover-gates.mjs
candidate=0123456789abcdef0123456789abcdef01234567
scratch=$(mktemp -d "${TMPDIR:-/tmp}/cutover-gates.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() {
  printf 'cutover gate fixtures: %s\n' "$*" >&2
  exit 1
}
assert_allowed_source_diff() {
  local changed
  while IFS= read -r changed; do
    [[ -z "$changed" ]] && continue
    case "$changed" in
      .ci/cutover-gates.json|.ci/device-evidence/*) ;;
      *)
        printf 'source changed after measured commit: %s\n' "$changed" >&2
        return 1
        ;;
    esac
  done
}

if [[ ${1:-} == "--assert-allowed-source-diff" ]]; then
  [[ $# -eq 1 ]] || fail "--assert-allowed-source-diff takes no values"
  assert_allowed_source_diff
  exit 0
elif [[ $# -ne 0 ]]; then
  fail "unknown argument: $1"
fi


run_evaluator() {
  local output=$1
  shift
  set +e
  node "$evaluator" "$@" >"$output" 2>"$output.stderr"
  RUN_EXIT=$?
  set -e
  [[ ! -s "$output.stderr" ]] || {
    cat "$output.stderr" >&2
    fail "evaluator wrote unexpected stderr"
  }
  jq -e 'type == "object"' "$output" >/dev/null || fail "evaluator output is not one JSON object"
}

assert_exit() {
  local expected=$1 label=$2
  [[ "$RUN_EXIT" -eq "$expected" ]] || fail "$label exited $RUN_EXIT, expected $expected"
}

common=(
  --support-matrix "$fixtures/matrix.json"
  --gates "$fixtures/policy.json"
  --measured-gates "$fixtures/policy.json"
  --candidate-commit "$candidate"
)

open_output="$scratch/open.json"
run_evaluator "$open_output" "${common[@]}" \
  --evidence-dir "$fixtures/evidence/open" --require G0,G1a,G1b
assert_exit "$(jq -r '.exit' "$fixtures/expected-open.json")" "open evidence"
jq -e --slurpfile expected "$fixtures/expected-open.json" \
  '. == {gates: $expected[0].gates}' "$open_output" >/dev/null ||
  fail "open evidence output drifted from expected-open.json"

closed_output="$scratch/closed.json"
run_evaluator "$closed_output" "${common[@]}" \
  --evidence-dir "$fixtures/evidence/closed" --require none
assert_exit "$(jq -r '.cases[] | select(.require == "none") | .exit' "$fixtures/expected-closed.json")" \
  "closed evidence with no required gates"
jq -e --slurpfile expected "$fixtures/expected-closed.json" \
  '. == {gates: ($expected[0].cases[] | select(.require == "none") | .gates)}' \
  "$closed_output" >/dev/null || fail "closed evidence output drifted from expected-closed.json"

blocked_output="$scratch/blocked.json"
run_evaluator "$blocked_output" "${common[@]}" \
  --evidence-dir "$fixtures/evidence/closed" --require G0,G1b
assert_exit "$(jq -r '.cases[] | select(.require == "G0,G1b") | .exit' "$fixtures/expected-closed.json")" \
  "closed delivery gates"
cmp -s "$closed_output" "$blocked_output" ||
  fail "required-gate selection changed deterministic closed output"

while IFS=$'\t' read -r file fragment; do
  output="$scratch/invalid-${file}.json"
  run_evaluator "$output" "${common[@]}" --evidence "$fixtures/evidence/invalid/$file" --require none
  assert_exit "$(jq -r '.exit' "$fixtures/expected-invalid.json")" "invalid evidence $file"
  jq -e --arg fragment "$fragment" '
    (keys == ["errors"]) and
    (.errors | type == "array" and length == 1 and
      (.[0] | type == "string" and contains($fragment)))
  ' "$output" >/dev/null || fail "invalid evidence $file output drifted from expected fragment: $fragment"
done < <(jq -r '.cases | to_entries[] | [.key, .value] | @tsv' "$fixtures/expected-invalid.json")

while IFS=$'\t' read -r file fragment; do
  output="$scratch/matrix-${file}.json"
  run_evaluator "$output" \
    --support-matrix "$fixtures/$file" \
    --gates "$fixtures/policy.json" \
    --measured-gates "$fixtures/policy.json" \
    --candidate-commit "$candidate" --evidence-dir "$fixtures/evidence/open" --require none
  assert_exit "$(jq -r '.exit' "$fixtures/expected-schema-negatives.json")" "invalid matrix $file"
  jq -e --arg fragment "$fragment" '
    (keys == ["errors"]) and
    (.errors | type == "array" and length == 1 and
      (.[0] | type == "string" and contains($fragment)))
  ' "$output" >/dev/null || fail "invalid matrix $file output drifted from expected fragment: $fragment"
done < <(jq -r '.matrix | to_entries[] | [.key, .value] | @tsv' "$fixtures/expected-schema-negatives.json")

while IFS=$'\t' read -r file fragment; do
  output="$scratch/policy-${file}.json"
  run_evaluator "$output" \
    --support-matrix "$fixtures/matrix.json" \
    --gates "$fixtures/$file" \
    --measured-gates "$fixtures/$file" \
    --candidate-commit "$candidate" --evidence-dir "$fixtures/evidence/open" --require none
  assert_exit "$(jq -r '.exit' "$fixtures/expected-schema-negatives.json")" "invalid policy $file"
  jq -e --arg fragment "$fragment" '
    (keys == ["errors"]) and
    (.errors | type == "array" and length == 1 and
      (.[0] | type == "string" and contains($fragment)))
  ' "$output" >/dev/null || fail "invalid policy $file output drifted from expected fragment: $fragment"
done < <(jq -r '.policy | to_entries[] | [.key, .value] | @tsv' "$fixtures/expected-schema-negatives.json")

lifecycle_expected="$fixtures/expected-policy-lifecycle.json"
positive_current=$(jq -r '.positive.current' "$lifecycle_expected")
positive_measured=$(jq -r '.positive.measured' "$lifecycle_expected")
positive_output_fixture=$(jq -r '.positive.output' "$lifecycle_expected")
lifecycle_positive_output="$scratch/policy-lifecycle-positive.json"
run_evaluator "$lifecycle_positive_output" \
  --support-matrix "$fixtures/matrix.json" \
  --gates "$fixtures/$positive_current" \
  --measured-gates "$fixtures/$positive_measured" \
  --candidate-commit "$candidate" --evidence-dir "$fixtures/evidence/open" --require G0,G1a,G1b
assert_exit "$(jq -r '.positive.exit' "$lifecycle_expected")" "measured outcome-only policy drift"
jq -e --slurpfile expected "$fixtures/$positive_output_fixture" \
  '. == {gates: $expected[0].gates}' "$lifecycle_positive_output" >/dev/null ||
  fail "outcome-only measured policy changed gate evaluation output"

negative_current=$(jq -r '.negative.current' "$lifecycle_expected")
negative_measured=$(jq -r '.negative.measured' "$lifecycle_expected")
negative_fragment=$(jq -r '.negative.error' "$lifecycle_expected")
lifecycle_negative_output="$scratch/policy-lifecycle-negative.json"
run_evaluator "$lifecycle_negative_output" \
  --support-matrix "$fixtures/matrix.json" \
  --gates "$fixtures/$negative_current" \
  --measured-gates "$fixtures/$negative_measured" \
  --candidate-commit "$candidate" --evidence-dir "$fixtures/evidence/open" --require none
assert_exit "$(jq -r '.negative.exit' "$lifecycle_expected")" "candidate authorization drift"
jq -e --arg fragment "$negative_fragment" '
  (keys == ["errors"]) and
  (.errors | type == "array" and length == 1 and
    (.[0] | type == "string" and contains($fragment)))
' "$lifecycle_negative_output" >/dev/null ||
  fail "candidate authorization drift output changed"

jq -r '.sourceDiff.positive[]' "$lifecycle_expected" |
  assert_allowed_source_diff ||
  fail "allowed post-measurement policy/evidence paths were rejected"

source_diff_error="$scratch/source-diff-negative.stderr"
set +e
jq -r '.sourceDiff.negative[]' "$lifecycle_expected" |
  assert_allowed_source_diff 2>"$source_diff_error"
source_diff_exit=$?
set -e
[[ "$source_diff_exit" -eq "$(jq -r '.sourceDiff.exit' "$lifecycle_expected")" ]] ||
  fail "forbidden post-measurement source path exited $source_diff_exit"
source_diff_fragment=$(jq -r '.sourceDiff.error' "$lifecycle_expected")
grep -F -- "$source_diff_fragment" "$source_diff_error" >/dev/null ||
  fail "forbidden post-measurement source path error drifted"

printf '%s\n' 'cutover gate fixture validation passed'
