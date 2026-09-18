#!/usr/bin/env bash
set -euo pipefail

# The lock job's compound-engineering hold-back. Run it after the resolver wrote
# the working lock and before the digest check. It puts the committed
# compound-engineering entry back unless the overlay patches survive the release
# the resolver found, and it never touches another tool's entry.
#
# USAGE
#   ce-overlay-lock-hold.sh [--lock FILE] [--committed-lock FILE]
#       [--overlay-dir DIR] [--pristine-dir DIR]
#
#   --lock FILE            working lock (default: the repository's releases.json)
#   --committed-lock FILE  lock to compare with and restore from (default:
#                          `git show HEAD:` of --lock)
#   --overlay-dir DIR      overlay directory (default: the repository's own)
#   --pristine-dir DIR     upstream files, replacing the download; tests use it
#
# STEPS
#   Same compound-engineering version in both locks: nothing to do, the gate is
#   never called. A resolved version outside the compound-engineering-v<semver>
#   form, or one that is not newer than the committed one: restore, no rebase
#   candidate. Otherwise the gate runs in candidate mode against the resolved tag:
#     valid        stamp base.json to the tag, run the gate again in pinned mode
#                  (a failure there rolls the stamp and the lock back)
#     invalid      restore; the release is a rebase candidate
#     unavailable  restore; no candidate, so a fetch failure never starts a rebase
#
# OUTPUT. stdout is exactly one line:
#   result=valid|held|unchanged candidate=yes|no class=<class|none> resolved=<tag> pin=<tag>
# `pin` is the committed version. Everything else goes to stderr, and a hold-back
# adds a job-summary notice. A hold-back exits 0 so the job stays green. Exit 1 is
# a tooling failure, 64 a usage error or a missing tool.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.ci/lib/source-root.sh
source "$repo_root/.ci/lib/source-root.sh"
# shellcheck source=.ci/lib/ce-overlay.sh
source "$repo_root/.ci/lib/ce-overlay.sh"
# shellcheck source=.ci/lib/bun.sh
source "$repo_root/.ci/lib/bun.sh"

TOOL=compound-engineering

usage_error() {
  printf 'ce-overlay-lock-hold: %s\n' "$1" >&2
  exit 64
}

die() {
  printf 'ce-overlay-lock-hold: %s\n' "$1" >&2
  exit 1
}

lock=''
committed=''
overlay_dir=''
pristine_dir=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --lock | --committed-lock | --overlay-dir | --pristine-dir)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case $1 in
        --lock) lock=$2 ;;
        --committed-lock) committed=$2 ;;
        --overlay-dir) overlay_dir=$2 ;;
        --pristine-dir) pristine_dir=$2 ;;
      esac
      shift 2
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

if [[ -z $lock ]]; then
  lock=$(join_source_state "$repo_root" .chezmoidata/releases.json)
fi
if [[ -z $overlay_dir ]]; then
  overlay_dir=$(join_source_state "$repo_root" dot_local/share/compound-engineering-overlays)
fi

missing=$(ceo_missing_tool jq git) || true
[[ -z $missing ]] || usage_error "required tool not found: $missing"
[[ -f $lock ]] || usage_error "working lock not found: $lock"

scratch_root=${RUNNER_TEMP:-${XDG_RUNTIME_DIR:-"$HOME/.cache"}}
mkdir -p -- "$scratch_root"
scratch=$(mktemp -d "$scratch_root/ce-overlay-lock-hold.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

if [[ -z $committed ]]; then
  committed="$scratch/committed-lock.json"
  git -C "$(dirname -- "$lock")" show "HEAD:./$(basename -- "$lock")" >"$committed" 2>"$scratch/git.err" ||
    die "cannot read the committed lock: $(<"$scratch/git.err")"
fi
[[ -f $committed ]] || usage_error "committed lock not found: $committed"

gate="$repo_root/.ci/check-ce-overlay-patches.sh"
driver="$repo_root/.ci/ce-overlay-rebase.sh"
common=(--overlay-dir "$overlay_dir" --lock "$lock")
if [[ -n $pristine_dir ]]; then
  common+=(--pristine-dir "$pristine_dir")
fi

entry_version() { jq -r --arg tool "$TOOL" '.releases.tools[$tool].version // ""' "$1"; }

pin=$(entry_version "$committed")
resolved=$(entry_version "$lock")
[[ -n $pin ]] || die "the committed lock has no $TOOL entry"

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._+-' '_' | cut -c1-64; }

emit() { # <result> <candidate yes|no> <class>
  printf 'result=%s candidate=%s class=%s resolved=%s pin=%s\n' \
    "$1" "$2" "$(slug "$3")" "$(slug "${resolved:-none}")" "$(slug "$pin")"
}

# tag_newer <a> <b>: true when compound-engineering-v<a> is a newer semver than <b>.
tag_newer() {
  local -a a b
  local i
  IFS=. read -r -a a <<<"${1#compound-engineering-v}"
  IFS=. read -r -a b <<<"${2#compound-engineering-v}"
  for i in 0 1 2; do
    if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
    if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
  done
  return 1
}

restore_entry() {
  local restored wanted
  resolve_bun
  [[ -n $BUN_BIN ]] || die 'bun is required to restore the committed lock entry'
  "$BUN_BIN" "$repo_root/packages/release-lock/src/cli.ts" \
    --restore-tool "$TOOL" --from "$committed" --out "$lock" >&2 ||
    die "cannot restore the $TOOL entry"
  restored=$(jq -S -c --arg tool "$TOOL" '.releases.tools[$tool]' "$lock")
  wanted=$(jq -S -c --arg tool "$TOOL" '.releases.tools[$tool]' "$committed")
  [[ $restored == "$wanted" ]] || die "the restored $TOOL entry differs from the committed one"
}

# hold <candidate yes|no> <class> <message>
hold() {
  local text
  text="$TOOL $(slug "${resolved:-none}") is held back at $(slug "$pin") ($(slug "$2")). $3"
  restore_entry
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    printf '::notice title=%s release held back::%s\n' "$TOOL" "$text" >&2
  else
    printf 'ce-overlay-lock-hold: %s\n' "$text" >&2
  fi
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '### %s release held back\n\n%s\n' "$TOOL" "$text" >>"$GITHUB_STEP_SUMMARY" || true
  fi
  emit held "$1" "$2"
  exit 0
}

# run_tool <program> <args...>: sets rc and out; stderr passes through.
rc=0
out=''
run_tool() {
  rc=0
  out=$("$@") || rc=$?
}

class_of() { sed -n 's/^class=//p' <<<"$1" | tail -n 1; }

if [[ $resolved == "$pin" ]]; then
  printf 'ce-overlay-lock-hold: %s is unchanged at %s\n' "$TOOL" "$pin" >&2
  emit unchanged no none
  exit 0
fi

if ! ceo_tag_valid "$resolved"; then
  hold no malformed-tag "The resolved version is not a compound-engineering-v<semver> tag, so it cannot be validated. No rebase is dispatched."
fi
if ! ceo_tag_valid "$pin" || ! tag_newer "$resolved" "$pin"; then
  hold no not-newer "The resolved version is not newer than the committed one. No rebase is dispatched."
fi

run_tool "$gate" "${common[@]}" --candidate-tag "$resolved"
gate_class=$(class_of "$out")
case $rc in
  0) ;;
  1) hold yes "${gate_class:-invalid}" "The overlay patches do not survive this release. A rebase is a candidate." ;;
  2) hold no unavailable "Upstream could not be fetched, so the release was not validated. No rebase is dispatched." ;;
  *) die "the overlay gate failed with status $rc" ;;
esac

base="$overlay_dir/base.json"
cp -p -- "$base" "$scratch/base.orig"
rollback() {
  cp -p -- "$scratch/base.orig" "$base.rollback"
  mv -f -- "$base.rollback" "$base"
}

run_tool "$driver" stamp "${common[@]}" --target-tag "$resolved"
printf '%s\n' "$out" >&2
case $rc in
  0) ;;
  1) hold yes stamp-refused "base.json could not be stamped to the new release. A rebase is a candidate." ;;
  2) hold no unavailable "Upstream could not be fetched, so the release was not stamped. No rebase is dispatched." ;;
  *) die "the overlay driver failed with status $rc" ;;
esac

run_tool "$gate" "${common[@]}"
gate_class=$(class_of "$out")
[[ $rc == 0 ]] || rollback
case $rc in
  0) ;;
  1) hold yes "${gate_class:-invalid}" "The stamped patch set failed the pinned-mode gate. A rebase is a candidate." ;;
  2) hold no unavailable "Upstream could not be fetched for the pinned-mode check. No rebase is dispatched." ;;
  *) die "the overlay gate failed with status $rc" ;;
esac

printf 'ce-overlay-lock-hold: %s advances from %s to %s and base.json is stamped\n' "$TOOL" "$pin" "$resolved" >&2
emit valid no valid
