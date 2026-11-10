#!/usr/bin/env bash
set -euo pipefail

script=${1:-}
if [[ $# -ne 1 || -z $script || ! -f $script ]]; then
  printf 'usage: %s NR_SCRIPT\n' "${0##*/}" >&2
  exit 2
fi
script=$(cd -- "$(dirname -- "$script")" && pwd -P)/$(basename -- "$script")

scratch=$(mktemp -d "${TMPDIR:-/tmp}/nr-tests.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
export HOME=$scratch/home
mkdir -p "$HOME"

fail() { printf 'nr: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'nr: ok - %s\n' "$*"; }

expect_failure() {
  local status=0
  err=$("$@" 2>&1 >/dev/null) || status=$?
  [[ $status -ne 0 ]] || fail "expected non-zero status: $*"
}

git_bin=$(command -v git) || fail 'git is required'
rendered=$scratch/nr
sed -e "s|@GIT@|$git_bin|" -e "s|@NVD@|/nonexistent/nvd|" "$script" >"$rendered"
chmod +x "$rendered"
export NR_DRY_RUN=1

make_repo() {
  local dir=$1
  mkdir -p "$dir"
  "$git_bin" -C "$dir" init -q
  "$git_bin" -C "$dir" config user.email t@example.invalid
  "$git_bin" -C "$dir" config user.name Test
  printf '{}\n' >"$dir/flake.nix"
  "$git_bin" -C "$dir" add flake.nix
  "$git_bin" -C "$dir" commit -qm init
}

repo=$scratch/repo
make_repo "$repo"

# --- resolution ------------------------------------------------------------

out=$("$rendered" build --flake-dir "$repo" --host testhost 2>/dev/null)
[[ $out == *"$repo#nixosConfigurations.testhost.config.system.build.toplevel"* ]] ||
  fail "build did not resolve the flake reference: $out"
pass 'build resolves the flake reference from --flake-dir and --host'

out=$("$rendered" switch --flake-dir "$repo" --host other-host 2>/dev/null)
[[ $out == *"$repo#other-host"* ]] || fail "--host override ignored: $out"
pass '--host overrides the detected hostname'

detected=$(uname -n)
out=$("$rendered" switch --flake-dir "$repo" 2>/dev/null)
[[ $out == *"$repo#$detected"* ]] || fail "hostname default not used: $out"
pass 'the target defaults to the running hostname'

# --- flake directory resolution -------------------------------------------

nonrepo=$scratch/plain
mkdir -p "$nonrepo"
if (cd "$nonrepo" && "$rendered" build >/dev/null 2>&1); then
  fail 'running outside a git repository should fail'
fi
expect_failure bash -c 'cd "$1" && "$2" build' _ "$nonrepo" "$rendered"
[[ $err == *--flake-dir* ]] || fail "failure outside a repo does not name --flake-dir: $err"
pass 'outside a git repository it fails and names --flake-dir'

noflake=$scratch/noflake
make_repo "$noflake"
rm -f "$noflake/flake.nix"
expect_failure bash -c 'cd "$1" && "$2" build' _ "$noflake" "$rendered"
[[ $err == *--flake-dir* ]] || fail "repo without flake.nix does not name --flake-dir: $err"
pass 'a git repository with no flake.nix fails and names --flake-dir'

# --- untracked warning -----------------------------------------------------

err=$("$rendered" build --flake-dir "$repo" --host testhost 2>&1 >/dev/null)
[[ -z $err ]] || fail "clean tree still warned: $err"
pass 'a clean tree produces no untracked warning'

printf 'x\n' >"$repo/new-module.nix"
err=$("$rendered" build --flake-dir "$repo" --host testhost 2>&1 >/dev/null)
[[ $err == *new-module.nix* ]] || fail "untracked file not reported: $err"
out=$("$rendered" build --flake-dir "$repo" --host testhost 2>/dev/null)
[[ $out == *nixosConfigurations* ]] || fail 'untracked warning aborted the run'
pass 'an untracked file is named on stderr and the run continues'
rm -f "$repo/new-module.nix"

# --- host-variant marker ---------------------------------------------------

marker=$scratch/variant
printf 'bootstrap\n' >"$marker"
export NR_VARIANT_FILE=$marker

for sub in switch boot test; do
  if "$rendered" "$sub" --flake-dir "$repo" >/dev/null 2>&1; then
    fail "$sub on a bootstrap generation should refuse without --host"
  fi
  expect_failure "$rendered" "$sub" --flake-dir "$repo"
  [[ $err == *--host* ]] || fail "$sub refusal does not name --host: $err"
done
pass 'switch, boot and test refuse on a bootstrap generation without --host'

out=$("$rendered" switch --flake-dir "$repo" --host explicit 2>/dev/null)
[[ $out == *"$repo#explicit"* ]] || fail "explicit --host still refused: $out"
pass 'an explicit --host proceeds on a bootstrap generation'

out=$("$rendered" build --flake-dir "$repo" 2>/dev/null)
[[ $out == *nixosConfigurations* ]] || fail 'unprivileged build was refused'
pass 'build is unaffected by the bootstrap marker'

printf 'production\n' >"$marker"
out=$("$rendered" switch --flake-dir "$repo" 2>/dev/null)
[[ $out == *"$repo#"* ]] || fail 'production marker blocked the run'
pass 'a production marker does not stop the run'

export NR_VARIANT_FILE=$scratch/absent-marker
out=$("$rendered" switch --flake-dir "$repo" 2>/dev/null)
[[ $out == *"$repo#"* ]] || fail 'absent marker blocked the run'
pass 'an absent marker does not stop the run'

# --- generation diff target ------------------------------------------------

out=$("$rendered" switch --flake-dir "$repo" --host testhost 2>/dev/null)
[[ $out == *"diff-target: /run/current-system"* ]] ||
  fail "switch does not diff against /run/current-system: $out"
out=$("$rendered" test --flake-dir "$repo" --host testhost 2>/dev/null)
[[ $out == *"diff-target: /run/current-system"* ]] ||
  fail "test does not diff against /run/current-system: $out"
pass 'switch and test diff against /run/current-system'

out=$("$rendered" boot --flake-dir "$repo" --host testhost 2>/dev/null)
[[ $out == *"diff-target: /nix/var/nix/profiles/system"* ]] ||
  fail "boot does not diff against the system profile: $out"
pass 'boot diffs against /nix/var/nix/profiles/system, which it actually updates'

# --- argument validation ---------------------------------------------------

unset NR_VARIANT_FILE
for bad in "--host" "--flake-dir"; do
  expect_failure "$rendered" switch --flake-dir "$repo" "$bad"
  [[ $err == *"missing value for $bad"* ]] || fail "$bad with no value not rejected: $err"
done
pass 'a flag with no value exits non-zero naming the flag'

expect_failure "$rendered" switch --flake-dir "$repo" --bogus
[[ $err == *"unexpected argument --bogus"* ]] || fail "unknown flag not rejected: $err"
pass 'an unknown flag exits non-zero naming it'

# --- the post-rebuild generation diff --------------------------------------
# Everything above runs under NR_DRY_RUN, which returns before the rebuild.
# These drive the real control flow with the privileged command and nvd stubbed.

unset NR_DRY_RUN
stub_dir=$scratch/stubs
mkdir -p "$stub_dir"
# A sudo stub that actually runs what it is given, so the rebuild below really
# executes; `sudo -v` (no command) is a no-op.
cat >"$stub_dir/sudo" <<STUB
#!$(command -v bash)
[[ \${1:-} == -v ]] && exit 0
[[ \${1:-} == -- ]] && shift
exec "\$@"
STUB
chmod +x "$stub_dir/sudo"
printf '#!%s\nprintf "nvd-called %%s\\n" "$*" >"%s/nvd.log"\n' "$(command -v bash)" "$scratch" >"$stub_dir/nvd"
chmod +x "$stub_dir/nvd"

# Re-render with the stub nvd so the substituted path is the recording one.
rendered_run=$scratch/nr-run
sed -e "s|@GIT@|$git_bin|" -e "s|^NVD=.*|NVD=\"$stub_dir/nvd\"|" "$script" >"$rendered_run"
chmod +x "$rendered_run"

mkdir -p "$scratch/genA" "$scratch/genB"
export NR_CURRENT=$scratch/current
export NR_PROFILE=$scratch/profile

# A rebuild stub that repoints whichever generation link NR_STUB_MOVES names,
# so the before/after sampling sees a real change mid-run the way a rebuild
# produces one. Naming nothing leaves both links alone.
printf '#!%s\n[[ -n ${NR_STUB_MOVES:-} ]] && ln -sfn "%s/genB" "$NR_STUB_MOVES"\nexit 0\n' \
  "$(command -v bash)" "$scratch" >"$stub_dir/rebuild-stub"
chmod +x "$stub_dir/rebuild-stub"
export NR_NIXOS_REBUILD=$stub_dir/rebuild-stub

reset_generations() {
  ln -sfn "$scratch/genA" "$scratch/current"
  ln -sfn "$scratch/genA" "$scratch/profile"
  rm -f "$scratch/nvd.log" "$scratch/refresh.log"
}

refresh=$HOME/.local/share/nix-config/refresh-agent-instructions
mkdir -p "$(dirname "$refresh")"
printf '#!%s\nprintf "refreshed\\n" >>"%s/refresh.log"\n' "$(command -v bash)" "$scratch" >"$refresh"
chmod +x "$refresh"

reset_generations
NR_STUB_MOVES= out=$(PATH=$stub_dir:$PATH "$rendered_run" switch --flake-dir "$repo" --host testhost 2>&1)
[[ $out == *"produced no change"* ]] || fail "unchanged generation not reported: $out"
[[ ! -f $scratch/nvd.log ]] || fail 'nvd was called even though the generation did not change'
[[ $(cat "$scratch/refresh.log") == refreshed ]] || fail 'unchanged switch did not refresh instructions once'
pass 'an unchanged generation reports no change and does not call nvd'

# switch samples /run/current-system, so moving that link must be what it sees.
reset_generations
NR_STUB_MOVES=$scratch/current PATH=$stub_dir:$PATH \
  "$rendered_run" switch --flake-dir "$repo" --host testhost >/dev/null 2>&1
[[ -f $scratch/nvd.log ]] || fail 'nvd was not called after switch changed the generation'
grep -qxF "nvd-called diff $scratch/genA $scratch/genB" "$scratch/nvd.log" ||
  fail "switch diffed the wrong pair: $(cat "$scratch/nvd.log")"
pass 'switch diffs the before and after of /run/current-system, in that order'
[[ $(cat "$scratch/refresh.log") == refreshed ]] || fail 'changed switch did not refresh instructions once'

reset_generations
PATH=$stub_dir:$PATH "$rendered_run" test --flake-dir "$repo" --host testhost >/dev/null 2>&1
[[ $(cat "$scratch/refresh.log") == refreshed ]] || fail 'test apply did not refresh instructions'

# boot does not activate, so only the system profile moves. Start from links
# that already diverge -- the state a previous boot leaves behind -- because
# with both at the same generation a baseline read from /run/current-system
# yields the same pair as one read from the profile, and the assertion could
# not tell a correct implementation from the bug it guards.
mkdir -p "$scratch/genC"
rm -f "$scratch/nvd.log" "$scratch/refresh.log"
ln -sfn "$scratch/genA" "$scratch/current"
ln -sfn "$scratch/genB" "$scratch/profile"
printf '#!%s\nln -sfn "%s/genC" "%s/profile"\nexit 0\n' \
  "$(command -v bash)" "$scratch" "$scratch" >"$stub_dir/rebuild-stub"
chmod +x "$stub_dir/rebuild-stub"
PATH=$stub_dir:$PATH "$rendered_run" boot --flake-dir "$repo" --host testhost >/dev/null 2>&1
[[ ! -e $scratch/refresh.log ]] || fail 'boot-only rebuild refreshed running instructions'
[[ -f $scratch/nvd.log ]] || fail 'nvd was not called after boot changed the system profile'
grep -qxF "nvd-called diff $scratch/genB $scratch/genC" "$scratch/nvd.log" ||
  fail "boot did not diff the profile's own before and after: $(cat "$scratch/nvd.log")"
pass 'boot diffs the system profile against itself, not against current-system'

# Restore the parameterised stub for the remaining cases.
printf '#!%s\n[[ -n ${NR_STUB_MOVES:-} ]] && ln -sfn "%s/genB" "$NR_STUB_MOVES"\nexit 0\n' \
  "$(command -v bash)" "$scratch" >"$stub_dir/rebuild-stub"
chmod +x "$stub_dir/rebuild-stub"

# A failing nvd must not turn a successful rebuild into a failure.
printf '#!%s\nexit 3\n' "$(command -v bash)" >"$stub_dir/nvd"
chmod +x "$stub_dir/nvd"
rendered_fail=$scratch/nr-nvdfail
sed -e "s|@GIT@|$git_bin|" -e "s|^NVD=.*|NVD=\"$stub_dir/nvd\"|" "$script" >"$rendered_fail"
chmod +x "$rendered_fail"
reset_generations
if ! NR_STUB_MOVES=$scratch/current PATH=$stub_dir:$PATH \
  "$rendered_fail" switch --flake-dir "$repo" --host testhost >/dev/null 2>&1; then
  fail 'a failing nvd made a successful rebuild look failed'
fi
pass 'a failing nvd is reported but does not fail the run'

reset_generations
printf '#!%s\nexit 19\n' "$(command -v bash)" >"$refresh"
printf '#!%s\nprintf "diffed\\n" >"%s/nvd.log"\n' "$(command -v bash)" "$scratch" >"$stub_dir/nvd"
expect_failure env NR_STUB_MOVES="$scratch/current" PATH="$stub_dir:$PATH" "$rendered_run" switch --flake-dir "$repo" --host testhost
[[ $(readlink -f "$scratch/current") == "$scratch/genB" ]] || fail 'refresh-failure case did not actually apply'
[[ $err == *'configuration applied, but agent instruction refresh failed'* ]] || fail 'partial apply failure is not explained'
[[ -e $scratch/nvd.log ]] || fail 'refresh failure skipped the generation diff'

reset_generations
printf '#!%s\nexit 17\n' "$(command -v bash)" >"$stub_dir/rebuild-stub"
expect_failure env PATH="$stub_dir:$PATH" "$rendered_run" switch --flake-dir "$repo" --host testhost
[[ ! -e $scratch/refresh.log ]] || fail 'failed rebuild refreshed instructions'

NR_DRY_RUN=1 PATH=$stub_dir:$PATH "$rendered_run" switch --flake-dir "$repo" --host testhost >/dev/null 2>&1
[[ ! -e $scratch/refresh.log ]] || fail 'dry run refreshed instructions'

unset NR_NIXOS_REBUILD NR_CURRENT NR_PROFILE
export NR_DRY_RUN=1

# --- usage -----------------------------------------------------------------

expect_failure "$rendered" frobnicate --flake-dir "$repo"
[[ $err == *"unknown subcommand"* ]] || fail "unknown subcommand message missing: $err"
pass 'an unknown subcommand exits non-zero with usage'

printf 'nr: all checks passed\n'
