#!/usr/bin/env bash
set -euo pipefail

# Tests the decision and reporting logic of both NuPhy Gem80 firmware gates:
#   1. `.ci/check-gem80-firmware-pins.sh` (daily reachability gate)
#   2. `.ci/check-gem80-firmware-rebuild.sh` (weekly rebuild gate)
#
# NON-MUTATING EVALUATION (KTD4, U5).
# Both gates expose an `--eval` interface so their decision logic, failure
# reporting, and manifest validation can be tested on synthetic fixtures
# without network access or container builds.
#
# COVERAGE.
#   * R7: Rebuild gate fails when actual sha differs from recorded sha under
#     `rebuildMode: match-sha256`.
#   * R8: Rebuild gate passes when actual sha differs from recorded sha under
#     `rebuildMode: build-only`.
#   * R10: Error distinction: failure messages identify the specific cause
#     (commit ahead/behind/diverged/404/query error, image unreachable,
#     build output mismatch) and report all failing checks together.
#   * Manifest and build record validation: malformed JSON, missing fields,
#     invalid sha/digest formats, and missing files are rejected.
#   * Baseline: committed repository files pass both gates in eval mode.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pins_gate="$repo_root/.ci/check-gem80-firmware-pins.sh"
rebuild_gate="$repo_root/.ci/check-gem80-firmware-rebuild.sh"
fixtures="$repo_root/.ci/fixtures/gem80-firmware"

[ -x "$pins_gate" ] || {
  printf 'gem80-firmware-pin-gates: missing or non-executable %s\n' "$pins_gate" >&2
  exit 1
}

[ -x "$rebuild_gate" ] || {
  printf 'gem80-firmware-pin-gates: missing or non-executable %s\n' "$rebuild_gate" >&2
  exit 1
}

case_name=
out=

fail() {
  printf 'gem80-firmware-pin-gates [%s]: %s\n' "$case_name" "$*" >&2
  [ -z "$out" ] || printf -- '--- gate output ---\n%s\n-------------------\n' "$out" >&2
  exit 1
}

pass() {
  printf 'gem80-firmware-pin-gates: ok - %s\n' "$1"
}

run_rebuild() {
  out=$("$rebuild_gate" "$@" 2>&1) && return 0 || return $?
}

run_pins() {
  out=$("$pins_gate" "$@" 2>&1) && return 0 || return $?
}

rebuild_accepts() {
  case_name=$1
  local what=$2
  shift 2
  out=
  local rc=0
  run_rebuild "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0, got exit $rc"
  pass "$what"
}

rebuild_rejects() {
  case_name=$1
  local expected=$2
  local what=$3
  shift 3
  out=
  local rc=0
  run_rebuild "$@" || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1, got exit $rc"
  case "$out" in
    *"$expected"*) ;;
    *) fail "output does not name '$expected'" ;;
  esac
  pass "$what"
}

pins_accepts() {
  case_name=$1
  local what=$2
  shift 2
  out=
  local rc=0
  run_pins "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0, got exit $rc"
  pass "$what"
}

pins_rejects() {
  case_name=$1
  local expected=$2
  local what=$3
  shift 3
  out=
  local rc=0
  run_pins "$@" || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1, got exit $rc"
  case "$out" in
    *"$expected"*) ;;
    *) fail "output does not name '$expected'" ;;
  esac
  pass "$what"
}

matching_sha="964eed3f305427f11363e8227c151a25097ab594524edcd5aa224627b825a2c4"
mismatch_sha="0000000000000000000000000000000000000000000000000000000000000000"

# --------------------------------------------------------------------------- #
# Rebuild Gate (.ci/check-gem80-firmware-rebuild.sh) Evaluation Tests
# --------------------------------------------------------------------------- #

# Both reproducibility modes accept an exact sha256 match.
rebuild_accepts match-sha256-matching \
  'rebuild gate passes when output matches recorded sha256 in match-sha256 mode' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-match-sha256.yaml"

rebuild_accepts build-only-matching \
  'rebuild gate passes when output matches recorded sha256 in build-only mode' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

# Covers R7: match-sha256 mode requires bit-for-bit output match.
rebuild_rejects match-sha256-mismatch \
  'output mismatch: rebuilt binary sha256' \
  'rebuild gate fails when output differs from recorded sha256 in match-sha256 mode (R7)' \
  --eval "$mismatch_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-match-sha256.yaml"

# Covers R8: build-only mode accepts sha divergence with a notice.
rebuild_accepts build-only-mismatch \
  'rebuild gate passes when output differs from recorded sha256 in build-only mode (R8)' \
  --eval "$mismatch_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

# Rebuild input validation and malformed fixture rejection.
rebuild_rejects invalid-actual-sha \
  'is not a 64-character lowercase hex digest' \
  'rebuild gate rejects non-hex or non-64-character actual sha' \
  --eval 'bad-sha' \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

rebuild_rejects missing-build-record \
  'build record not found' \
  'rebuild gate rejects non-existent build-info file' \
  --eval "$matching_sha" \
  --build-info "$fixtures/nonexistent.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

rebuild_rejects malformed-build-record \
  'build record is not valid JSON object' \
  'rebuild gate rejects malformed JSON build record' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-malformed.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

rebuild_rejects missing-binary-name \
  'build record carries no binary.name' \
  'rebuild gate rejects build record missing binary.name' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-missing-binary-name.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

rebuild_rejects invalid-binary-sha \
  'build record carries no valid binary.sha256' \
  'rebuild gate rejects build record with invalid binary.sha256' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-invalid-binary-sha.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

rebuild_rejects missing-firmware-yaml \
  'firmware data file not found' \
  'rebuild gate rejects non-existent firmware.yaml file' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/nonexistent.yaml"

rebuild_rejects invalid-rebuild-mode \
  'invalid or missing rebuildMode' \
  'rebuild gate rejects invalid rebuildMode value' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-invalid-rebuild-mode.yaml"

# Baseline: real committed files pass rebuild gate in eval mode.
real_recorded_sha=$(jq -r '.binary.sha256 // empty' "$repo_root/firmware/nuphy-gem80-hostrgb/dist/build-info.json")
[ -n "$real_recorded_sha" ] || fail 'could not read binary.sha256 from committed build-info.json'

rebuild_accepts committed-files \
  'rebuild gate passes against committed repository files in eval mode' \
  --eval "$real_recorded_sha"

# --------------------------------------------------------------------------- #
# Pins Gate (.ci/check-gem80-firmware-pins.sh) Evaluation Tests
# --------------------------------------------------------------------------- #

# Normal reachability passes: identical or ahead with behind_by 0.
pins_accepts commit-identical-image-ok \
  'pins gate passes when commit is identical and image is ok' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_accepts commit-ahead-image-ok \
  'pins gate passes when commit is ahead with behind_by 0' \
  --eval \
  --commit-status ahead \
  --behind-by 0 \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

# Covers R10: each failure type produces a message identifying its specific cause.
pins_rejects commit-behind \
  'is not reachable from refs/heads/nuphy-keyboards in ryodeushii/qmk-firmware (commit is ahead of branch)' \
  'pins gate identifies commit ahead of branch (R10)' \
  --eval \
  --commit-status behind \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects commit-ahead-behind-by \
  'is not an ancestor of refs/heads/nuphy-keyboards in ryodeushii/qmk-firmware (branch is behind by 2 commits)' \
  'pins gate identifies branch behind by commits (R10)' \
  --eval \
  --commit-status ahead \
  --behind-by 2 \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects commit-diverged \
  'has diverged from refs/heads/nuphy-keyboards in ryodeushii/qmk-firmware (branch is behind by 5 commits)' \
  'pins gate identifies diverged branch (R10)' \
  --eval \
  --commit-status diverged \
  --behind-by 5 \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects commit-not-found \
  'fork commit 9847cb81729fa6540ffed1a583b9acdaaa20607b or ref refs/heads/nuphy-keyboards not found in ryodeushii/qmk-firmware' \
  'pins gate identifies commit or ref not found (R10)' \
  --eval \
  --commit-status 404 \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects commit-query-error \
  'reachability query failed for refs/heads/nuphy-keyboards in ryodeushii/qmk-firmware (error:API_RATE_LIMIT)' \
  'pins gate identifies query error status (R10)' \
  --eval \
  --commit-status error:API_RATE_LIMIT \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects image-unreachable \
  'toolchain image ghcr.io/qmk/qmk_cli@sha256:b7d7fa8fb4432b569931de5ad59098cb788f440ed61a62c5126746b71aee0f4a is not reachable in registry (error:HTTP_404)' \
  'pins gate identifies unreachable toolchain image (R10)' \
  --eval \
  --commit-status identical \
  --image-status error:HTTP_404 \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json"

# Covers R10: failure isolation reports BOTH commit and image errors when both fail.
case_name=dual-failure-isolation
out=
rc=0
run_pins \
  --eval \
  --commit-status diverged \
  --behind-by 3 \
  --image-status error:HTTP_500 \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json" || rc=$?
[ "$rc" -eq 1 ] || fail "expected exit 1, got exit $rc"
case "$out" in
  *"has diverged from"*) ;;
  *) fail "output does not report commit divergence error" ;;
esac
case "$out" in
  *"is not reachable in registry"*) ;;
  *) fail "output does not report image registry error" ;;
esac
pass 'pins gate reports both commit and image errors when both fail (failure isolation, R10)'

# Eval flag enforcement.
pins_rejects eval-missing-status \
  '--eval requires --commit-status and --image-status' \
  'pins gate requires status flags with --eval' \
  --eval

pins_rejects status-without-eval \
  '--commit-status and --image-status are only valid with --eval' \
  'pins gate refuses status flags outside --eval' \
  --commit-status identical

# Pins input validation and malformed fixture rejection.
pins_rejects missing-manifest \
  'firmware manifest not found' \
  'pins gate rejects non-existent firmware manifest' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/nonexistent.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects missing-manifest-fields \
  'firmware manifest missing required fields' \
  'pins gate rejects firmware manifest missing required fields' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-missing-fork-fields.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects invalid-fork-sha \
  'invalid fork commit sha format' \
  'pins gate rejects invalid fork commit sha format' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-invalid-sha.yaml" \
  --build-info "$fixtures/build-info-valid.json"

pins_rejects missing-build-info \
  'build info not found' \
  'pins gate rejects non-existent build-info file' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/nonexistent.json"

pins_rejects malformed-build-info \
  'build info is not valid JSON' \
  'pins gate rejects malformed JSON build info' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-malformed.json"

pins_rejects missing-toolchain-image \
  'build info missing toolchainImage' \
  'pins gate rejects build info missing toolchainImage' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-missing-toolchain-image.json"

pins_rejects invalid-toolchain-digest \
  'toolchainImage missing valid @sha256 digest' \
  'pins gate rejects toolchainImage missing @sha256 digest' \
  --eval \
  --commit-status identical \
  --image-status ok \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-invalid-toolchain-image.json"

# Baseline: real committed files pass pins gate in eval mode.
pins_accepts committed-files \
  'pins gate passes against committed repository files in eval mode' \
  --eval \
  --commit-status identical \
  --image-status ok

printf 'gem80-firmware-pin-gates: all cases passed\n'
