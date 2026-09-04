#!/usr/bin/env bash
# test-skip-record-pruning.sh — verify prune_stale_skip_records in the chezmoi
# read-source-state.pre hook.
#
# WHAT IT GUARDS. A transient skip record is written by the site that took the
# skip and cleared by nothing else: only a later declaration carrying the same
# script/site pair removes the file, and a wait-only site has no success-path
# twin. Two live records outlived their conditions that way — the NVIDIA akmods
# wait after the signing key was minted, and the mise-trust wait after mise was
# installed — so `dotfiles-skips` reported converged hosts as outstanding.
#
# The pruner is driven for real: the hook is sourced through its unit-test seam
# and its functions are called against a scratch state tree, with the capability
# verdicts seeded the way write_capability_cache would have published them.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo_root/.install-prerequisites.sh"
[[ -f "$hook" ]] || { printf 'test-skip-record-pruning: missing %s\n' "$hook" >&2; exit 1; }

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/test-skip-record-pruning.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'test-skip-record-pruning: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-skip-record-pruning: ok - %s\n' "$*"; }

# shellcheck source=/dev/null
_INSTALL_PREREQUISITES_TEST_SOURCE=1 source "$hook"

for fn in prune_stale_skip_records capability_token capability_has; do
  declare -F "$fn" >/dev/null || fail "the hook does not define $fn"
done
pass 'the hook exposes the pruner and its capability lookup'

# The snapshot write_capability_cache would have published. Two probes, one of
# each verdict, so a record can wait on either.
# shellcheck disable=SC2034 # read by the sourced hook's capability_token.
CAPABILITY_KEYS=(mise-present session-bus-present)
# shellcheck disable=SC2034 # read by the sourced hook's capability_token.
CAPABILITY_TOKENS=(available unavailable)

[[ "$(capability_token mise-present)" == available ]] ||
  fail 'capability_token does not return the published verdict'
[[ "$(capability_token session-bus-present)" == unavailable ]] ||
  fail 'capability_token does not return the published verdict'
if capability_token not-in-the-registry >/dev/null 2>&1; then
  fail 'capability_token must fail for a key the registry does not declare'
fi
pass 'capability_token answers from the published snapshot and fails for an unknown key'

skips_dir=''
seed_records() {
  export XDG_STATE_HOME="$scratch/state-$1"
  skips_dir="$XDG_STATE_HOME/chezmoi/skips"
  rm -rf -- "$XDG_STATE_HOME"
  mkdir -p "$skips_dir"
  # Written exactly as skip.sh.tmpl writes them.
  printf 'v1\tmise-trust\tmise-absent\ttransient-blocking:mise-present\tmise not installed\n' \
    > "$skips_dir/mise-trust__mise-absent"
  printf 'v1\tconfig-gnome\tno-bus\ttransient-blocking:session-bus-present\tno D-Bus session bus\n' \
    > "$skips_dir/config-gnome__no-bus"
  printf 'v1\tinstall-vscodium\text-fail\ttransient-tolerable\tfailed to install extension\n' \
    > "$skips_dir/install-vscodium__ext-fail"
  printf 'v1\tinstall-nvidia-fedora\tbranch-conflict\toperator-blocking\ta conflicting driver branch is installed\n' \
    > "$skips_dir/install-nvidia-fedora__branch-conflict"
  printf 'v1\tconfig-fx\tunknown-probe\ttransient-blocking:not-in-the-registry\tsome unlisted precondition\n' \
    > "$skips_dir/config-fx__unknown-probe"
  printf 'v1\tconfig-fx\tsideways\tsideways\ta direction this pruner does not know\n' \
    > "$skips_dir/config-fx__sideways"
  printf 'not-a-record\n' > "$skips_dir/00-malformed"
}

# --- A command that runs no scripts must prune nothing -----------------------
#
# `status` and `diff` render the source state but execute none of it, so a record
# retired there is one nothing would rewrite: the host would read as converged
# while the script is still pending.
for cmd in status diff verify doctor ''; do
  seed_records "readonly-${cmd:-none}"
  CHEZMOI_COMMAND="$cmd" prune_stale_skip_records ||
    fail "the pruner must never fail the hook (command ${cmd:-unset})"
  [[ -f "$skips_dir/mise-trust__mise-absent" ]] ||
    fail "a read-only command (${cmd:-unset}) pruned a record no script will rewrite"
  [[ -f "$skips_dir/install-vscodium__ext-fail" ]] ||
    fail "a read-only command (${cmd:-unset}) pruned a tolerable record"
done
pass 'commands that run no scripts prune nothing'

# --- An applying command retires exactly the cleared records -----------------
for cmd in apply update init; do
  seed_records "applying-$cmd"
  CHEZMOI_COMMAND="$cmd" prune_stale_skip_records ||
    fail "the pruner must never fail the hook (command $cmd)"

  # transient-blocking whose probe now reads available: the fingerprint has
  # changed, so this same command re-runs the script.
  [[ ! -e "$skips_dir/mise-trust__mise-absent" ]] ||
    fail "$cmd did not retire a blocking record whose probe is now available"

  # transient-blocking whose probe is still unavailable: still outstanding.
  [[ -f "$skips_dir/config-gnome__no-bus" ]] ||
    fail "$cmd retired a blocking record whose probe is still unavailable"

  # transient-tolerable: exits 1, so chezmoi never recorded the run and the
  # script retries on every apply, rewriting this if it still fails.
  [[ ! -e "$skips_dir/install-vscodium__ext-fail" ]] ||
    fail "$cmd did not retire a tolerable record; those retry on every apply"

  # operator-blocking KEEPS its record by contract: nothing changes the rendered
  # content when the operator clears the condition, so the script does not re-run
  # and this record is the only thing still reporting the host.
  [[ -f "$skips_dir/install-nvidia-fedora__branch-conflict" ]] ||
    fail "$cmd retired an operator-blocking record; that direction keeps its record"

  # Unparseable or unrecognised input is LEFT ALONE. Over-reporting a converged
  # host is a nuisance; deleting the only record of an unconverged one is a lie.
  [[ -f "$skips_dir/config-fx__unknown-probe" ]] ||
    fail "$cmd retired a record naming a probe the registry does not declare"
  [[ -f "$skips_dir/config-fx__sideways" ]] ||
    fail "$cmd retired a record whose direction this pruner does not know"
  [[ -f "$skips_dir/00-malformed" ]] ||
    fail "$cmd retired a malformed record instead of leaving it to be reported"
done
pass 'an applying command retires cleared blocking and tolerable records only'

# --- The reader agrees ------------------------------------------------------
#
# End to end against the real dotfiles-skips: what survives the prune is exactly
# what an operator is still asked to look at.
dotfiles_skips="$repo_root/dot_local/share/chezmoi-command-sources/executable_dotfiles-skips"
seed_records reader
CHEZMOI_COMMAND=apply prune_stale_skip_records
out=$("$dotfiles_skips" 2>/dev/null)
if grep -qF 'mise-trust' <<<"$out"; then
  fail 'dotfiles-skips still reports a wait whose probe has cleared'
fi
if grep -qF 'install-vscodium' <<<"$out"; then
  fail 'dotfiles-skips still reports a tolerable record the apply will rewrite'
fi
grep -qF 'config-gnome' <<<"$out" ||
  fail 'dotfiles-skips must still report a wait whose probe is unavailable'
grep -qF 'install-nvidia-fedora' <<<"$out" ||
  fail 'dotfiles-skips must still report the operator-blocking record'
pass 'dotfiles-skips reports exactly what survives the prune'

# --- Never fails the hook ---------------------------------------------------
#
# A record that cannot be removed is a stale report, not a wrong render, so
# nothing here may abort every chezmoi command. An unwritable directory is the
# case that used to be tempting to treat as fatal.
seed_records unwritable
chmod 500 "$skips_dir"
CHEZMOI_COMMAND=apply prune_stale_skip_records ||
  fail 'an unremovable record must not fail the hook'
chmod 700 "$skips_dir"
pass 'an unwritable state directory does not fail the hook'

export XDG_STATE_HOME="$scratch/state-absent"
CHEZMOI_COMMAND=apply prune_stale_skip_records ||
  fail 'an absent state directory must not fail the hook'
pass 'an absent state directory does not fail the hook'

printf 'test-skip-record-pruning: all tests passed\n'
