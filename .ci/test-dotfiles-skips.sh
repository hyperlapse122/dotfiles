#!/usr/bin/env bash
# test-dotfiles-skips.sh — verify dotfiles-skips reporting and safety invariants.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dotfiles_skips="$repo_root/dot_local/share/chezmoi-command-sources/executable_dotfiles-skips"

if [[ ! -x "$dotfiles_skips" ]]; then
  printf 'test-dotfiles-skips: error: executable not found at %s\n' "$dotfiles_skips" >&2
  exit 1
fi

scratch_parent=${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}
mkdir -p "$scratch_parent"
scratch=$(mktemp -d "$scratch_parent/test-dotfiles-skips.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'test-dotfiles-skips: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'test-dotfiles-skips: ok - %s\n' "$*"; }

"$dotfiles_skips" --help >/dev/null || fail '--help failed'
"$dotfiles_skips" -h >/dev/null || fail '-h failed'
pass '--help and -h exit 0'

if "$dotfiles_skips" --invalid-flag >/dev/null 2>&1; then
  fail 'invalid option should exit non-zero'
fi
pass 'invalid option exits non-zero'

export XDG_STATE_HOME="$scratch/absent-state"
out=$("$dotfiles_skips")
[[ -z "$out" ]] || fail 'absent directory should produce empty output'
pass 'absent state directory produces empty output'

export XDG_STATE_HOME="$scratch/empty-state"
mkdir -p "$XDG_STATE_HOME/chezmoi/skips"
out=$("$dotfiles_skips")
[[ -z "$out" ]] || fail 'empty directory should produce empty output'
pass 'empty state directory produces empty output'

export XDG_STATE_HOME="$scratch/mixed-state"
skips_dir="$XDG_STATE_HOME/chezmoi/skips"
mkdir -p "$skips_dir"

printf 'v1\tconfig-gnome\tno-bus\ttransient-blocking:session-bus-present\tno D-Bus session bus\n' \
  > "$skips_dir/config-gnome__no-bus"
printf 'v1\tinstall-vscodium\text-fail\ttransient-tolerable\tfailed to install extension\n' \
  > "$skips_dir/install-vscodium__ext-fail"
printf 'v1\tconfig-kde\twrong-desktop\tharmless\tnot a KDE desktop\n' \
  > "$skips_dir/config-kde__wrong-desktop"
# operator-blocking is outstanding too: the host has not converged, and nothing
# re-runs the script on its own, so the report is the only place it shows up.
printf 'v1\tinstall-nvidia-fedora\tbranch-conflict\toperator-blocking\ta conflicting driver branch is installed\n' \
  > "$skips_dir/install-nvidia-fedora__branch-conflict"

out=$("$dotfiles_skips")
expected=$(printf 'config-gnome\tno-bus\ttransient-blocking:session-bus-present\tno D-Bus session bus\ninstall-nvidia-fedora\tbranch-conflict\toperator-blocking\ta conflicting driver branch is installed\ninstall-vscodium\text-fail\ttransient-tolerable\tfailed to install extension')
[[ "$out" == "$expected" ]] || fail "unexpected output for mixed records:\nGot:\n$out\nExpected:\n$expected"
pass 'mixed records report every outstanding direction and omit harmless'

# An unknown direction must still warn: adding a direction to skip.sh.tmpl without
# adding it here would silently drop an outstanding skip from the report.
sideways_err=$(printf 'v1\tconfig-fx\tsideways\tsideways\ta direction this reader does not know\n' \
  > "$skips_dir/config-fx__sideways" && "$dotfiles_skips" 2>&1 >/dev/null)
grep -qF 'unknown direction' <<<"$sideways_err" \
  || fail "an unknown direction was not warned about: $sideways_err"
rm -f "$skips_dir/config-fx__sideways"
pass 'an unknown direction is reported as a warning'

rm -f "$skips_dir/config-gnome__no-bus" "$skips_dir/install-nvidia-fedora__branch-conflict"
out=$("$dotfiles_skips")
expected=$(printf 'install-vscodium\text-fail\ttransient-tolerable\tfailed to install extension')
[[ "$out" == "$expected" ]] || fail "completed record was not cleared:\nGot:\n$out\nExpected:\n$expected"
pass 'cleared record is no longer reported'

printf 'bad-version\tfoo\tbar\ttransient-tolerable\treason\n' > "$skips_dir/00-malformed"
printf 'v1\tvalid-script\tsite-a\ttransient-tolerable\tvalid reason\n' > "$skips_dir/zz-valid"

stderr_file="$scratch/stderr.log"
out=$("$dotfiles_skips" 2>"$stderr_file")
[[ -s "$stderr_file" ]] || fail 'malformed record should emit warning on stderr'
grep -q 'warning: malformed record' "$stderr_file" || fail 'stderr missing malformed warning'
grep -q 'valid-script' <<< "$out" || fail 'valid record after malformed entry was dropped'
pass 'malformed record emits warning and preserves subsequent valid records'

rm -rf "$skips_dir"
mkdir -p "$skips_dir"
target_file="$scratch/secret-target"
printf 'v1\tsecret-script\tleak\ttransient-tolerable\tsecret payload\n' > "$target_file"
ln -s "$target_file" "$skips_dir/symlink-record"

out=$("$dotfiles_skips")
[[ -z "$out" ]] || fail "symlink record was unexpectedly read: $out"
pass 'symlinked skip records are ignored'

unreadable_dir="$scratch/unreadable-state/chezmoi/skips"
mkdir -p "$unreadable_dir"
chmod 000 "$unreadable_dir"
export XDG_STATE_HOME="$scratch/unreadable-state"
if "$dotfiles_skips" >/dev/null 2>&1; then
  chmod 700 "$unreadable_dir"
  fail 'unreadable directory should exit non-zero'
fi
chmod 700 "$unreadable_dir"
pass 'unreadable state directory exits non-zero'

out=$("$dotfiles_skips")
[[ -z "$out" ]] || fail "symlink record was unexpectedly read: $out"
pass 'symlinked skip records are ignored'

# 9. Unreadable state directory exits 1
unreadable_dir="$scratch/unreadable-state/chezmoi/skips"
mkdir -p "$unreadable_dir"
chmod 000 "$unreadable_dir"
export XDG_STATE_HOME="$scratch/unreadable-state"
if "$dotfiles_skips" >/dev/null 2>&1; then
  chmod 700 "$unreadable_dir"
  fail 'unreadable directory should exit non-zero'
fi
chmod 700 "$unreadable_dir"
pass 'unreadable state directory exits non-zero'

printf 'test-dotfiles-skips: all tests passed\n'
