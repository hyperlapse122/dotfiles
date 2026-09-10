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
#   * R16: The weekly rebuild copies `patches/` into its scratch source tree.
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

# Both gates are asserted the same way, so the scaffolding takes the gate as an
# argument. Per-gate copies drift: strengthening one assertion and forgetting its
# twin weakens half the suite without failing anything.
gate_accepts() {
  local gate=$1 what=$3
  case_name=$2
  shift 3
  out=
  local rc=0
  out=$("$gate" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0, got exit $rc"
  pass "$what"
}

gate_rejects() {
  local gate=$1 expected=$3 what=$4
  case_name=$2
  shift 4
  out=
  local rc=0
  out=$("$gate" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1, got exit $rc"
  case "$out" in
    *"$expected"*) ;;
    *) fail "output does not name '$expected'" ;;
  esac
  pass "$what"
}

rebuild_accepts() { gate_accepts "$rebuild_gate" "$@"; }
rebuild_rejects() { gate_rejects "$rebuild_gate" "$@"; }
pins_accepts() { gate_accepts "$pins_gate" "$@"; }
pins_rejects() { gate_rejects "$pins_gate" "$@"; }

# From the fixture these cases actually point the gate at. Reading the live
# record here would fail these fixture cases the day the firmware is rebuilt;
# the committed-files case below reads that record separately, on purpose.
matching_sha=$(jq -r '.binary.sha256' "$fixtures/build-info-valid.json")
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

# The weekly gate copies the source tree before rendering the build command.
# Eval mode runs that copy against small source fixtures so this path stays
# testable without a container or network access.
rebuild_accepts patches-carried-to-scratch \
  'rebuild gate carries patches into its scratch source copy' \
  --eval "$matching_sha" \
  --source-fixture "$fixtures/source-with-patches" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

case_name=patches-carried-to-scratch-output
out=$("$rebuild_gate" \
  --eval "$matching_sha" \
  --source-fixture "$fixtures/source-with-patches" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" 2>&1)
case "$out" in
  *'scratch copy carries patches/'*) ;;
  *) fail 'rebuild gate did not report patches in the scratch source copy' ;;
esac
pass 'rebuild gate reports that the scratch source copy carries patches'

rebuild_rejects scratch-copy-missing-patches \
  'scratch source is missing patches/' \
  'rebuild gate rejects a scratch source copy without patches' \
  --eval "$matching_sha" \
  --source-fixture "$fixtures/source-without-patches" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

# Passing is only half of R8. build-only accepting a divergence silently would
# make the weaker mode indistinguishable from a clean reproduction, so the
# notice is the part worth asserting.
case_name=build-only-mismatch-notice
out=$("$rebuild_gate" \
  --eval "$mismatch_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" 2>&1)
case "$out" in
  *'notice: output sha256'*) ;;
  *) fail 'build-only mode accepted a divergence without reporting it' ;;
esac
case "$out" in
  *'::warning::'*) ;;
  *) fail 'build-only divergence did not surface as a workflow warning' ;;
esac
pass 'rebuild gate reports the divergence it accepts under build-only mode (R8)'

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

# binary.name selects the path the gate hashes, so a record pointing outside
# dist/ must be refused rather than silently compared against another file.
rebuild_rejects traversal-binary-name \
  "this board's artifact is" \
  'rebuild gate rejects a build record naming a path outside the artifact' \
  --eval "$matching_sha" \
  --build-info "$fixtures/build-info-traversal-binary-name.json" \
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
# Written out rather than through gate_rejects, which asserts one substring and
# so cannot express that both causes must appear.
case_name=dual-failure-isolation
out=
rc=0
out=$("$pins_gate" \
  --eval \
  --commit-status diverged \
  --behind-by 3 \
  --image-status error:HTTP_500 \
  --firmware-yaml "$fixtures/firmware-build-only.yaml" \
  --build-info "$fixtures/build-info-valid.json" 2>&1) || rc=$?
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
  'status overrides are only valid with --eval' \
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

# --------------------------------------------------------------------------- #
# Submodule reachability (the build's other three remote dependencies)
# --------------------------------------------------------------------------- #

pins_accepts submodules-ok \
  'pins gate passes when every submodule commit is still served' \
  --eval --commit-status identical --image-status ok \
  --submodule-status 'lib/chibios=ok' \
  --submodule-status 'lib/chibios-contrib=ok' \
  --submodule-status 'lib/printf=ok'

pins_rejects submodule-gone \
  'no longer serves' \
  'pins gate fails when a submodule commit is no longer served' \
  --eval --commit-status identical --image-status ok \
  --submodule-status 'lib/chibios=ok' \
  --submodule-status 'lib/printf=error:lib/printf pins qmk/printf@dead, which qmk/printf no longer serves'

pins_rejects submodule-unresolvable \
  'points outside github.com' \
  'pins gate fails when a submodule cannot be resolved rather than passing it' \
  --eval --commit-status identical --image-status ok \
  --submodule-status 'lib/printf=error:lib/printf points outside github.com (git://example.invalid/x); cannot check reachability'

# Every broken dependency is named in one run, not just the first reached.
case_name='all-three-streams-fail'
out=$("$pins_gate" \
  --eval --commit-status diverged --behind-by 2 --image-status error:HTTP_404 \
  --submodule-status 'lib/printf=error:lib/printf pins qmk/printf@dead, which qmk/printf no longer serves' 2>&1) || true
for expected in 'has diverged from' 'is not reachable in registry' 'no longer serves'; do
  case "$out" in
    *"$expected"*) ;;
    *) fail "combined failure output does not name '$expected'" ;;
  esac
done
pass 'pins gate names the fork, image and submodule failures together (failure isolation)'

# --------------------------------------------------------------------------- #
# 404 disambiguation: a stranded commit and a deleted one need different fixes
# --------------------------------------------------------------------------- #

pins_rejects commit-stranded \
  'still exists in' \
  'pins gate says the commit survives but left the branch when it does' \
  --eval --commit-status 404 --commit-exists yes --image-status ok

pins_rejects commit-deleted \
  'no longer exists in' \
  'pins gate says the commit is gone when it is' \
  --eval --commit-status 404 --commit-exists no --image-status ok

pins_rejects commit-404-unknown \
  'not found in' \
  'pins gate falls back to the unqualified message when existence is unknown' \
  --eval --commit-status 404 --image-status ok

# --------------------------------------------------------------------------- #
# Registry reference parsing (the part of the OCI client testable offline)
# --------------------------------------------------------------------------- #

# The gate guards main() behind a source check, so this pulls in its functions
# without running it.
# shellcheck source=.ci/check-gem80-firmware-pins.sh
source "$repo_root/.ci/check-gem80-firmware-pins.sh"

case_name='registry-manifest-url'
out=$(registry_manifest_url 'ghcr.io/qmk/qmk_cli@sha256:abc') || fail 'rejected a valid reference'
[ "$out" = 'https://ghcr.io/v2/qmk/qmk_cli/manifests/sha256:abc' ] ||
  fail "built the wrong manifest URL: $out"
pass 'registry reference splits into registry, repository and digest'

case_name='registry-manifest-url-rejects'
out=
registry_manifest_url 'ghcr.io/qmk/qmk_cli' >/dev/null 2>&1 &&
  fail 'accepted a reference with no digest'
registry_manifest_url 'qmk_cli@sha256:abc' >/dev/null 2>&1 &&
  fail 'accepted a reference with no registry'
pass 'registry reference parsing rejects references it cannot address'

case_name='registry-token-url'
out=$(registry_token_url 'Www-Authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:qmk/qmk_cli:pull"' 'qmk/qmk_cli')
[ "$out" = 'https://ghcr.io/token?service=ghcr.io&scope=repository:qmk/qmk_cli:pull' ] ||
  fail "built the wrong token URL: $out"
pass 'auth challenge becomes the token request it implies'

case_name='registry-token-url-defaults'
out=$(registry_token_url 'Www-Authenticate: Bearer realm="https://ghcr.io/token"' 'qmk/qmk_cli')
[ "$out" = 'https://ghcr.io/token?scope=repository:qmk/qmk_cli:pull' ] ||
  fail "wrong fallback token URL: $out"
registry_token_url 'Www-Authenticate: Basic' 'qmk/qmk_cli' >/dev/null 2>&1 &&
  fail 'accepted a challenge with no realm'
pass 'auth challenge falls back to a pull scope and refuses a realmless challenge'

# --------------------------------------------------------------------------- #
# Rebuild gate: the build-failure branch and the committed artifact
# --------------------------------------------------------------------------- #

rebuild_rejects build-failure \
  'build failure: firmware build failed' \
  'rebuild gate reports a build failure distinctly from an output mismatch (R10)' \
  --eval-build-failed --eval "$matching_sha" \
  --build-info "$fixtures/build-info-valid.json" \
  --firmware-yaml "$fixtures/firmware-build-only.yaml"

printf 'gem80-firmware-pin-gates: all cases passed\n'
