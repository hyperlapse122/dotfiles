#!/usr/bin/env bash
set -euo pipefail

# `~/.local/bin/orca` shadows the GNOME screen reader so a dispatched agent that runs the bare
# `orca` Orca writes into its own worker preamble reaches the Orca IDE CLI instead of starting
# speech. Both halves of that are asserted here: the wrapper's own resolution order, and the
# command-manifest gating that keeps the shadow on Linux only.
#
# The wrapper resolves explicit paths rather than searching PATH, so every branch is driven
# through its documented overrides and a stubbed HOME. A runner has no Orca install, and a gate
# that could only assert the error path would prove nothing about the path that matters.

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch_root="${XDG_RUNTIME_DIR:-${HOME:?HOME is required}/.cache}/agent-scratch"
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/orca-cli-shadow.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/home" "$scratch/target"
printf '[data]\n' >"$scratch/empty.toml"
printf '#!/usr/bin/env bash\nprintf dummy-secret\n' >"$scratch/bin/op"
chmod 700 "$scratch/bin/op"
chezmoi_bin=$(command -v chezmoi)

fail() { printf 'orca cli shadow: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

wrapper_source=dot_local/share/chezmoi-command-sources/executable_orca
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper_source"
wrapper="$repo_root/$wrapper_source"
[[ -x $wrapper ]] || fail "$wrapper_source is not executable in the source tree"

# Each stub records the argv it received, one argument per line, so an argument carrying a space
# is distinguishable from two arguments.
make_stub() {
  local path=$1 marker=$2
  mkdir -p -- "$(dirname -- "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf %%s\\\\n %s >"%s/called"\n' "$marker" "$scratch"
    printf ': >"%s/argv"\n' "$scratch"
    printf 'for a in "$@"; do printf %%s\\\\n "$a" >>"%s/argv"; done\n' "$scratch"
  } >"$path"
  chmod 755 "$path"
}

reset_probe() { rm -f -- "$scratch/called" "$scratch/argv"; }

called_marker() { cat -- "$scratch/called" 2>/dev/null || printf 'none\n'; }

home_cli="$scratch/home/.local/bin/orca-ide"
prefix_dir="$scratch/prefix"
prefix_cli="$prefix_dir/resources/bin/orca-ide"
explicit_cli="$scratch/explicit-orca-ide"
system_orca="$scratch/system-orca"
make_stub "$home_cli" home
make_stub "$prefix_cli" prefix
make_stub "$explicit_cli" explicit
make_stub "$system_orca" system

# The wrapper is only ever invoked through this helper, so no case can accidentally inherit the
# runner's real HOME, a real /opt/Orca, or the real /usr/bin/orca.
run_wrapper() {
  env -i HOME="$scratch/home" PATH="/usr/bin:/bin" \
    ORCA_PREFIX="$prefix_dir" ORCA_SYSTEM_ORCA="$system_orca" "$@" \
    bash "$wrapper" orchestration check --run run_x 'two words'
}

reset_probe
run_wrapper >/dev/null
[[ $(called_marker) == home ]] || fail "with a HOME candidate present the wrapper ran $(called_marker)"
mapfile -t argv <"$scratch/argv"
[[ ${#argv[@]} -eq 5 ]] || fail "expected 5 forwarded arguments, got ${#argv[@]}"
[[ ${argv[0]} == orchestration && ${argv[1]} == check && ${argv[2]} == --run && ${argv[3]} == run_x ]] \
  || fail "the wrapper altered the forwarded arguments: ${argv[*]}"
[[ ${argv[4]} == "two words" ]] || fail "an argument containing a space was split: ${argv[4]}"

reset_probe
mv -- "$home_cli" "$home_cli.hidden"
run_wrapper >/dev/null
[[ $(called_marker) == prefix ]] || fail "with only the prefix candidate the wrapper ran $(called_marker)"
mv -- "$home_cli.hidden" "$home_cli"

reset_probe
run_wrapper ORCA_IDE_CLI="$explicit_cli" >/dev/null
[[ $(called_marker) == explicit ]] || fail "an explicit CLI override lost to another candidate"

reset_probe
mv -- "$home_cli" "$home_cli.hidden"
mv -- "$prefix_cli" "$prefix_cli.hidden"
run_wrapper >/dev/null
[[ $(called_marker) == system ]] || fail "with no Orca IDE candidate the wrapper ran $(called_marker)"

reset_probe
missing_system="$scratch/absent-system-orca"
if output=$(env -i HOME="$scratch/home" PATH="/usr/bin:/bin" \
  ORCA_PREFIX="$prefix_dir" ORCA_SYSTEM_ORCA="$missing_system" \
  bash "$wrapper" 2>&1); then
  fail "with no candidate at all the wrapper exited 0"
fi
for expected in "$home_cli" "$prefix_cli" "$missing_system"; do
  grep -Fq -- "$expected" <<<"$output" || fail "the no-candidate error does not name $expected"
done

# A PATH lookup of `orca` would find the wrapper itself; this proves it never takes that path.
recursion_dir="$scratch/recursion"
mkdir -p "$recursion_dir"
cp -- "$wrapper" "$recursion_dir/orca"
chmod 755 "$recursion_dir/orca"
if timeout 20 env -i HOME="$scratch/home" PATH="$recursion_dir:/usr/bin:/bin" \
  ORCA_PREFIX="$prefix_dir" ORCA_SYSTEM_ORCA="$missing_system" \
  bash "$recursion_dir/orca" >/dev/null 2>&1; then
  fail "the wrapper exited 0 with its own directory first on PATH"
elif (( $? == 124 )); then
  fail "the wrapper recursed into itself when its own directory was first on PATH"
fi
mv -- "$home_cli.hidden" "$home_cli"
mv -- "$prefix_cli.hidden" "$prefix_cli"

manifest_include="$scratch/manifest.tmpl"
printf '%s' '{{ includeTemplate "command-manifest.tmpl" . }}' >"$manifest_include"
for os in linux darwin; do
  rendered="$scratch/manifest-$os.txt"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$manifest_include" "$rendered"
  [[ -s $rendered ]] || fail "the command manifest rendered empty for $os"
  if [[ $os == linux ]]; then
    grep -Fq 'orca-wrapper' "$rendered" || fail "the command manifest does not declare orca on linux"
  elif grep -Fq 'orca-wrapper' "$rendered"; then
    fail "the command manifest declares orca on darwin, where the screen reader is not the hazard"
  fi
done

printf 'orca cli shadow gates passed\n'
