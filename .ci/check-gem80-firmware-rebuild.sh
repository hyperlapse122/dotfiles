#!/usr/bin/env bash
set -euo pipefail

# check-gem80-firmware-rebuild.sh — rebuild gate for NuPhy Gem80 `hostrgb` firmware.
#
# TWO MODES OF EXECUTION.
#   1. Rebuild gate (default):
#      Rebuilds the firmware in an isolated scratch copy of the repository and
#      compares the newly produced binary against the committed build record.
#   2. Evaluation mode (--eval <actual-sha256> [build-info] [firmware-yaml]):
#      Evaluates the decision and reporting logic for a given artifact hash
#      against build-info and firmware data fixtures, without invoking container
#      builds or network access (U5).
#
# SCRATCH ISOLATION (KTD2, R5).
# `executable_gem80-firmware.tmpl` bakes `.chezmoi.sourceDir` into the rendered
# command at render time and writes build output directly to
# `$SOURCE_DIR/firmware/nuphy-gem80-hostrgb/dist/`. Running against the real
# checkout would overwrite the committed binary and record (violating R5). The
# gate therefore copies the repository to a temporary scratch directory and
# renders `gem80-firmware` with `--source "$scratch_repo"`, ensuring all build
# writes and updated records remain in scratch.
#
# COMMITTED RECORD BASELINE (KTD6, R6).
# The gate reads `binary.sha256` and `binary.name` from the committed
# `build-info.json` BEFORE the build runs. Comparison is always against this
# baseline, never against any new record the build writes.
#
# REPRODUCIBILITY MODES (KTD3, R7, R8).
# `.chezmoidata/firmware.yaml` (`firmware.gem80.rebuildMode`) declares the rule:
#   * `match-sha256`: output hash must match the committed record exactly (R7).
#   * `build-only`: build success is the sole passing criterion; hash mismatch
#     is reported as a notice but does not fail the gate (R8).
#
# ERROR DISTINCTION (R10).
# Failure messages distinguish between build failure and output mismatch.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# The one artifact `nuphy/gem80/ansi:hostrgb` produces. Pinned here so the build
# record cannot redirect the comparison at a different file.
EXPECTED_BIN_NAME=nuphy_gem80_ansi_hostrgb.bin

fail() {
  printf 'check-gem80-firmware-rebuild: %s\n' "$1" >&2
  [ -z "${2:-}" ] || printf '%s\n' "$2" >&2
  printf '::error::%s\n' "$1"
  exit 1
}

usage() {
  cat <<'EOF'
usage: check-gem80-firmware-rebuild.sh [options] [repo_dir]
       check-gem80-firmware-rebuild.sh --eval <sha256> [--source-fixture P] [--build-info P] [--firmware-yaml P]

Rebuild gate for NuPhy Gem80 hostrgb firmware.

Options:
  --eval, --eval-decision  Evaluate decision logic on a known hash without building
  --eval-build-failed      Eval only: report the build-failure branch and exit non-zero
  --sha, --actual-sha <h>  Specify the rebuilt artifact hash for eval mode
  --build-info <path>      Path to build-info.json (default: repo build record)
  --firmware-yaml <path>   Path to firmware.yaml (default: .chezmoidata/firmware.yaml)
  --source-fixture <path>  Eval only: copy a source fixture and check its patches/
  -h, --help               Show this help message
EOF
}

# shellcheck source=.ci/lib/gem80-firmware-data.sh
source "$repo_root/.ci/lib/gem80-firmware-data.sh"

eval_mode=false
eval_build_failed=false
actual_sha=""
custom_build_info=""
custom_firmware_yaml=""
source_fixture=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eval | --eval-decision | eval)
      eval_mode=true
      shift
      if [[ $# -gt 0 && $1 != --* ]]; then
        actual_sha="$1"
        shift
      fi
      ;;
    --eval-build-failed)
      eval_build_failed=true
      shift
      ;;
    --sha | --actual-sha)
      shift
      [[ $# -gt 0 ]] || fail "missing argument for $1"
      actual_sha="$1"
      shift
      ;;
    --build-info)
      shift
      [[ $# -gt 0 ]] || fail "missing argument for --build-info"
      custom_build_info="$1"
      shift
      ;;
    --build-info=*)
      custom_build_info="${1#*=}"
      shift
      ;;
    --firmware-yaml | --firmware-data)
      shift
      [[ $# -gt 0 ]] || fail "missing argument for $1"
      custom_firmware_yaml="$1"
      shift
      ;;
    --firmware-yaml=* | --firmware-data=*)
      custom_firmware_yaml="${1#*=}"
      shift
      ;;
    --source-fixture)
      shift
      [[ $# -gt 0 ]] || fail "missing argument for --source-fixture"
      source_fixture="$1"
      shift
      ;;
    --source-fixture=*)
      source_fixture="${1#*=}"
      shift
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      if [[ $eval_mode == true ]]; then
        # Named only. The sibling pins gate took its two files in the opposite
        # order, and a positional pair that silently swaps meaning between two
        # gates doing the same job is worth more than the keystrokes it saves.
        fail "unexpected argument '$1'; pass files as --build-info and --firmware-yaml"
      elif [[ -d $1 ]]; then
        repo_root=$(cd -- "$1" && pwd)
      else
        fail "unknown argument or option: $1"
      fi
      shift
      ;;
  esac
done

if [[ -n $source_fixture && $eval_mode != true ]]; then
  fail "--source-fixture is only valid with --eval"
fi

build_info="${custom_build_info:-$repo_root/firmware/nuphy-gem80-hostrgb/dist/build-info.json}"
firmware_yaml="${custom_firmware_yaml:-$repo_root/.chezmoidata/firmware.yaml}"

validate_inputs() {
  command -v jq >/dev/null 2>&1 || fail "jq is required on PATH"

  [[ -f $build_info ]] || fail "build record not found: $build_info"
  jq -e 'type == "object"' "$build_info" >/dev/null 2>&1 ||
    fail "build record is not valid JSON object: $build_info"

  recorded_name=$(jq -r '.binary.name // empty' "$build_info")
  recorded_sha=$(jq -r '.binary.sha256 // empty' "$build_info")

  # binary.name selects the path this gate hashes, so a record naming
  # ../../README.md would have the gate compare a source file instead of the
  # firmware. Only a bare filename is a legal artifact name.
  [[ -n $recorded_name ]] || fail "build record carries no binary.name: $build_info"
  [[ $recorded_name == "$EXPECTED_BIN_NAME" ]] ||
    fail "build record names '$recorded_name'; this board's artifact is '$EXPECTED_BIN_NAME'"
  [[ $recorded_sha =~ ^[0-9a-f]{64}$ ]] ||
    fail "build record carries no valid binary.sha256: $build_info"

  [[ -f $firmware_yaml ]] || fail "firmware data file not found: $firmware_yaml"

  rebuild_mode=$(gem80_firmware_yaml_get "$firmware_yaml" firmware.gem80.rebuildMode || true)
  case "$rebuild_mode" in
    build-only | match-sha256) ;;
    *)
      fail "invalid or missing rebuildMode in $firmware_yaml (expected 'build-only' or 'match-sha256', got '${rebuild_mode:-<empty>}')"
      ;;
  esac
}

copy_repo_to_scratch() {
  local source_dir="$1" scratch_dir="$2"

  [[ -d $source_dir ]] || fail "source tree not found: $source_dir"
  mkdir -p -- "$scratch_dir"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='.codegraph' "$source_dir/" "$scratch_dir/"
  else
    tar -C "$source_dir" --exclude='./.git' --exclude='./node_modules' --exclude='./.codegraph' -cf - . |
      tar -C "$scratch_dir" -xf -
  fi
}

assert_scratch_carries_patches() {
  local scratch_dir="$1"
  local patches_dir="$scratch_dir/firmware/nuphy-gem80-hostrgb/patches"

  [[ -d $patches_dir ]] ||
    fail "scratch source is missing patches/: $patches_dir"
  [[ -n $(find "$patches_dir" -mindepth 1 -maxdepth 1 -type f -print -quit) ]] ||
    fail "scratch source patches/ is empty: $patches_dir"
  printf 'check-gem80-firmware-rebuild: ok - scratch copy carries patches/ (%s)\n' "$patches_dir"
}

# One caller for the build-failure message, so the fixture test and the real
# build path cannot report it differently.
report_build_failure() {
  fail "build failure: firmware build failed in scratch tree"
}

# The rebuild proves the source still builds; it says nothing about the binary
# that is actually committed and flashed. A committed artifact that no longer
# matches its own record — an LFS mishap, a hand-edit, a bad merge — would sail
# through a passing rebuild, so it is checked separately and by name.
verify_committed_artifact() {
  local dist_bin="$1" rec_sha="$2"

  if [[ ! -f $dist_bin ]]; then
    printf 'check-gem80-firmware-rebuild: committed artifact absent (%s); skipping its check\n' "$dist_bin"
    printf '::warning::check-gem80-firmware-rebuild: committed artifact not present; only the rebuild was checked\n'
    return 0
  fi

  # An unfetched LFS pointer is a small text file, not firmware. Hashing it would
  # report a mismatch with a misleading cause.
  if head -c 64 -- "$dist_bin" | grep -q '^version https://git-lfs'; then
    printf 'check-gem80-firmware-rebuild: committed artifact is an unfetched Git LFS pointer; skipping its check\n'
    printf '::warning::check-gem80-firmware-rebuild: committed artifact is an LFS pointer; run git lfs pull to check it\n'
    return 0
  fi

  local dist_sha
  dist_sha=$(sha256sum -- "$dist_bin" | cut -d' ' -f1)
  if [[ $dist_sha != "$rec_sha" ]]; then
    fail "committed artifact mismatch: $dist_bin hashes to $dist_sha but the record says $rec_sha"
  fi
  printf 'check-gem80-firmware-rebuild: ok - committed artifact matches its record\n'
  return 0
}

evaluate_rebuild_result() {
  local act_sha="$1"
  local rec_sha="$2"
  local rec_name="$3"
  local mode="$4"

  printf 'check-gem80-firmware-rebuild: comparing output sha256 against recorded sha256\n'
  printf '  recorded: %s (%s)\n' "$rec_sha" "$rec_name"
  printf '  actual:   %s\n' "$act_sha"
  printf '  mode:     %s\n' "$mode"

  if [[ $act_sha == "$rec_sha" ]]; then
    printf 'check-gem80-firmware-rebuild: ok - output matches recorded sha256 (%s)\n' "$act_sha"
    return 0
  fi

  if [[ $mode == "match-sha256" ]]; then
    fail "output mismatch: rebuilt binary sha256 ($act_sha) does not match recorded sha256 ($rec_sha) (mode: match-sha256)"
  fi

  # Surfaced as a workflow warning, not just stdout: build-only is a one-word
  # setting that switches off the strongest assertion this gate makes, and a
  # divergence under it should be visible without opening the log.
  printf 'check-gem80-firmware-rebuild: notice: output sha256 (%s) differs from recorded sha256 (%s); accepted under build-only mode\n' \
    "$act_sha" "$rec_sha"
  printf '::warning::check-gem80-firmware-rebuild: rebuild did not reproduce the recorded binary; accepted because rebuildMode is build-only\n'
  printf 'check-gem80-firmware-rebuild: ok - build succeeded (rebuildMode: build-only)\n'
  return 0
}

if [[ $eval_mode == true ]]; then
  if [[ $eval_build_failed == true ]]; then
    # The build-failure branch is otherwise only reachable by making a real build
    # fail, which no fixture can arrange. It reports through the same call the
    # real path uses, so a test here covers the message the operator would see.
    validate_inputs
    report_build_failure
  fi

  [[ -n $actual_sha ]] || fail "eval mode requires an actual sha256 argument"
  [[ $actual_sha =~ ^[0-9a-f]{64}$ ]] ||
    fail "actual sha256 '$actual_sha' is not a 64-character lowercase hex digest"

  validate_inputs
  if [[ -n $source_fixture ]]; then
    eval_scratch_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gem80-rebuild-eval"
    mkdir -p -- "$eval_scratch_root"
    chmod 0700 -- "$eval_scratch_root"
    eval_scratch=$(mktemp -d "$eval_scratch_root/eval.XXXXXX")
    trap 'rm -rf -- "$eval_scratch"' EXIT
    eval_scratch_repo="$eval_scratch/repo"
    copy_repo_to_scratch "$source_fixture" "$eval_scratch_repo"
    assert_scratch_carries_patches "$eval_scratch_repo"
  fi
  evaluate_rebuild_result "$actual_sha" "$recorded_sha" "$recorded_name" "$rebuild_mode"
  exit 0
fi

# Full rebuild execution path
command -v chezmoi >/dev/null 2>&1 || fail "chezmoi is required on PATH (KTD1)"
command -v podman >/dev/null 2>&1 || fail "podman is required on PATH; rootless podman builds this firmware (R3)"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required on PATH"

validate_inputs

# Before the build, while the committed tree is still the only thing on disk.
verify_committed_artifact "$repo_root/firmware/nuphy-gem80-hostrgb/dist/$recorded_name" "$recorded_sha"

# $XDG_RUNTIME_DIR is tmpfs on Fedora and the repository copy is a few hundred MB,
# so the scratch tree lives under the cache directory rather than in RAM. This
# matches the same choice in executable_gem80-firmware.tmpl.
scratch_root=${XDG_CACHE_HOME:-$HOME/.cache}/gem80-rebuild
mkdir -p -- "$scratch_root"
chmod 0700 -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/rebuild.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

scratch_repo="$scratch/repo"
printf 'check-gem80-firmware-rebuild: copying repository to scratch (%s)\n' "$scratch_repo"
copy_repo_to_scratch "$repo_root" "$scratch_repo"
assert_scratch_carries_patches "$scratch_repo"

# The copy carries the committed binary at exactly the path this gate hashes
# afterwards. Left in place, a build that silently produced nothing would leave
# that file to be hashed and the gate would report a perfect match.
rm -rf -- "$scratch_repo/firmware/nuphy-gem80-hostrgb/dist"

rendered_cmd="$scratch/gem80-firmware"
template="$scratch_repo/dot_local/share/chezmoi-command-sources/executable_gem80-firmware.tmpl"
[[ -f $template ]] || fail "gem80-firmware template not found: $template"

printf '[data]\n' > "$scratch/empty.toml"
mkdir -p "$scratch/target"
printf 'check-gem80-firmware-rebuild: rendering gem80-firmware with --source %s\n' "$scratch_repo"
chezmoi --config "$scratch/empty.toml" --source "$scratch_repo" --destination "$scratch/target" \
  execute-template < "$template" > "$rendered_cmd" ||
  fail "failed to render gem80-firmware from scratch copy"
chmod 700 "$rendered_cmd"

printf 'check-gem80-firmware-rebuild: building firmware in scratch tree\n'
if ! "$rendered_cmd" build; then
  report_build_failure
fi

built_bin="$scratch_repo/firmware/nuphy-gem80-hostrgb/dist/$recorded_name"
[[ -f $built_bin ]] || fail "build failure: build produced no $recorded_name in scratch dist directory"

actual_sha=$(sha256sum -- "$built_bin" | cut -d' ' -f1)
[[ $actual_sha =~ ^[0-9a-f]{64}$ ]] || fail "failed to compute sha256 of rebuilt binary: $built_bin"

evaluate_rebuild_result "$actual_sha" "$recorded_sha" "$recorded_name" "$rebuild_mode"
