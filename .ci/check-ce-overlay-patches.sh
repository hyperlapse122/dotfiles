#!/usr/bin/env bash
set -euo pipefail

# One gate that validates the compound-engineering overlay patch set against an
# upstream release. CI, the lock job, and the rebase workflow all call it.
#
# USAGE
#   check-ce-overlay-patches.sh [--overlay-dir DIR] [--lock FILE]
#       [--candidate-tag TAG] [--pristine-dir DIR] [--allow-legacy-overlay-files]
#
#   --overlay-dir DIR   overlay directory that holds base.json and patches/**
#                       (default: the repository's own, resolved through the
#                       chezmoi source root)
#   --lock FILE         release lock that names the pin and the upstream source
#                       (default: the repository's releases.json)
#   --candidate-tag TAG validate against release TAG instead of the pin, and skip
#                       only the check that base.json's tag equals the pin
#   --pristine-dir DIR  read upstream files from DIR instead of downloading the
#                       tag archive; the offline test uses it
#   --allow-legacy-overlay-files
#                       do not refuse files outside patches/** and base.json in
#                       the overlay directory. It exists for the window in which
#                       the whole-file overlay copies still sit beside the
#                       patches; drop it wherever the copies are gone
#
# EXIT STATUS, with a matching `class=<value>` line on stdout
#   0  valid        class=valid
#   1  invalid      class=version-mismatch | schema | coverage |
#                   preimage-mismatch | removed-upstream | collision |
#                   patch-conflict | postimage-mismatch | contract
#   2  upstream unavailable   class=unavailable (a download or unpack failure,
#                   never reported as 1)
#  64  usage error or a missing local tool (no class line)
#
# ORDER. The cheap local checks run first (schema, pin, layout), then upstream
# is fetched, then pre-images, patch application, post-images, and the content
# contracts on the patched result. The first failing stage names the class.
# The download is the only network call.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
# shellcheck source=.ci/lib/ce-overlay.sh
source "$repo_root/.ci/lib/ce-overlay.sh"

overlay_dir=''
lock=''
candidate=''
pristine_src=''
allow_legacy=0

usage_error() {
  printf 'check-ce-overlay-patches: %s\n' "$1" >&2
  exit 64
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --overlay-dir | --lock | --candidate-tag | --pristine-dir)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case $1 in
        --overlay-dir) overlay_dir=$2 ;;
        --lock) lock=$2 ;;
        --candidate-tag) candidate=$2 ;;
        --pristine-dir) pristine_src=$2 ;;
      esac
      shift 2
      ;;
    --allow-legacy-overlay-files)
      allow_legacy=1
      shift
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

if [[ -z $overlay_dir ]]; then
  overlay_dir=$(join_source_state "$repo_root" dot_local/share/compound-engineering-overlays)
fi
if [[ -z $lock ]]; then
  lock=$(join_source_state "$repo_root" .chezmoidata/releases.json)
fi

missing=$(ceo_missing_tool jq git tar awk find stat chezmoi) || true
[[ -z $missing ]] || usage_error "required tool not found: $missing"
if [[ -z $pristine_src ]]; then
  missing=$(ceo_missing_tool curl) || true
  [[ -z $missing ]] || usage_error "required tool not found: $missing"
fi

ceo_scratch_init ce-overlay-gate

conclude() {
  local class=${1:-} status
  if [[ -z $class ]]; then
    class=$(ceo_pick_class)
  fi
  case $class in
    valid) status=0 ;;
    unavailable) status=2 ;;
    *) status=1 ;;
  esac
  if [[ $status != 0 ]]; then
    ceo_report_print
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
      printf '::error::compound-engineering overlay patches are not valid (class=%s)\n' "$class" >&2
    fi
  fi
  printf 'class=%s\n' "$class"
  exit "$status"
}

pinned=1
if [[ -n $candidate ]]; then
  pinned=0
  if ! ceo_tag_valid "$candidate"; then
    ceo_report schema - "candidate tag is not a compound-engineering-v<semver> tag: $candidate"
    conclude
  fi
fi

ceo_read_lock "$lock" "$pinned" || conclude
pin=$CEO_PIN

keyfile="$CEO_SCRATCH/keys"
base="$overlay_dir/base.json"
ceo_base_validate "$base" "$keyfile" || conclude
base_tag=$(jq -r '.version' "$base")

if [[ $pinned == 1 ]]; then
  fetch_tag=$pin
  if [[ $base_tag != "$pin" ]]; then
    ceo_report version-mismatch base.json "base.json records $base_tag but the pin is $pin"
    conclude
  fi
else
  fetch_tag=$candidate
fi

ceo_check_overlay_layout "$overlay_dir" "$keyfile" "$allow_legacy" || conclude

pristine="$CEO_SCRATCH/pristine"
status=0
ceo_load_pristine "$fetch_tag" "$pristine" "$keyfile" "$pristine_src" || status=$?
case $status in
  0) ;;
  2) conclude unavailable ;;
  *) conclude ;;
esac

ceo_check_preimages "$base" "$keyfile" "$pristine" || conclude

applied="$CEO_SCRATCH/applied"
mkdir -p -- "$applied"
ceo_apply_patches "$pristine" "$overlay_dir/patches" "$keyfile" "$applied" || conclude

ceo_check_postimages "$base" "$keyfile" "$applied" || conclude

authoring_effort=$(ceo_authoring_effort "$repo_root") || usage_error 'could not render the roster authoring effort'
ceo_check_contracts "$applied" "$keyfile" "$authoring_effort" || conclude

printf 'check-ce-overlay-patches: %s patches valid against %s\n' "$(wc -l <"$keyfile" | tr -d ' ')" "$fetch_tag" >&2
conclude valid
