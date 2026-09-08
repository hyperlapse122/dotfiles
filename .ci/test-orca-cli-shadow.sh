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

fail() { printf 'orca cli shadow: %s\n' "$*" >&2; exit 1; }
# shellcheck source=.ci/lib/render-gate-helpers.sh
source "$repo_root/.ci/lib/render-gate-helpers.sh"

chezmoi_bin=$(type -P chezmoi) || fail 'chezmoi is required on PATH'

wrapper_source=dot_local/share/chezmoi-command-sources/executable_orca
require_file "$repo_root" "$scratch" "$chezmoi_bin" "$wrapper_source"
wrapper="$repo_root/$wrapper_source"
[[ -x $wrapper ]] || fail "$wrapper_source is not executable in the source tree"

# Each stub records the argv it received, one argument per line, so an argument carrying a space
# is distinguishable from two arguments.
make_stub() {
  local path=$1 marker=$2
  mkdir -p -- "$(dirname -- "$path")"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' $marker >"$scratch/called"
: >"$scratch/argv"
for a in "\$@"; do printf '%s\n' "\$a" >>"$scratch/argv"; done
EOF
  chmod 755 "$path"
}

reset_probe() { rm -f -- "$scratch/called" "$scratch/argv"; }

called_marker() { cat -- "$scratch/called" 2>/dev/null || printf 'none\n'; }

home_cli="$scratch/home/.local/bin/orca-ide"
prefix_dir="$scratch/prefix"
prefix_cli="$prefix_dir/resources/bin/orca-ide"
explicit_cli="$scratch/explicit-orca-ide"
system_orca="$scratch/system-orca"
missing_system="$scratch/absent-system-orca"
make_stub "$home_cli" home
make_stub "$prefix_cli" prefix
make_stub "$explicit_cli" explicit
make_stub "$system_orca" system

# Every invocation below builds its environment from this one base, so no case can inherit the
# runner's real HOME, a real /opt/Orca, or the real /usr/bin/orca. Extra assignments passed to
# `run_wrapper` land after the base ones, and `env` lets the later assignment win.
wrapper_env=(env -i HOME="$scratch/home" PATH="/usr/bin:/bin"
  ORCA_PREFIX="$prefix_dir" ORCA_SYSTEM_ORCA="$system_orca")

run_wrapper() {
  "${wrapper_env[@]}" "$@" bash "$wrapper" orchestration check --run run_x 'two words'
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

# A present but non-executable candidate must be skipped, not treated as a hit. Absence alone would
# never exercise the `-x` test the resolution order depends on.
reset_probe
chmod 000 -- "$home_cli"
run_wrapper >/dev/null
[[ $(called_marker) == prefix ]] || fail "a non-executable HOME candidate was not skipped; the wrapper ran $(called_marker)"
chmod 755 -- "$home_cli"

reset_probe
mv -- "$home_cli" "$home_cli.hidden"
mv -- "$prefix_cli" "$prefix_cli.hidden"
run_wrapper >/dev/null
[[ $(called_marker) == system ]] || fail "with no Orca IDE candidate the wrapper ran $(called_marker)"

reset_probe
if output=$("${wrapper_env[@]}" ORCA_SYSTEM_ORCA="$missing_system" bash "$wrapper" 2>&1); then
  fail "with no candidate at all the wrapper exited 0"
fi
for expected in "$home_cli" "$prefix_cli" "$missing_system"; do
  grep -Fq -- "$expected" <<<"$output" || fail "the no-candidate error does not name $expected"
done

# A PATH lookup of `orca` would find the wrapper itself; this proves it never takes that path.
# `timeout` reports 124 when it kills the command, and `$?` inside this `elif` is still the status
# of the `if` condition, so 124 is what separates "recursed" from "exited non-zero for some other
# reason".
timeout_killed=124
recursion_dir="$scratch/recursion"
mkdir -p "$recursion_dir"
cp -- "$wrapper" "$recursion_dir/orca"
chmod 755 "$recursion_dir/orca"
if timeout 20 "${wrapper_env[@]}" PATH="$recursion_dir:/usr/bin:/bin" \
  ORCA_SYSTEM_ORCA="$missing_system" bash "$recursion_dir/orca" >/dev/null 2>&1; then
  fail "the wrapper exited 0 with its own directory first on PATH"
elif (( $? == timeout_killed )); then
  fail "the wrapper recursed into itself when its own directory was first on PATH"
fi

manifest_include="$scratch/manifest.tmpl"
printf '%s' '{{ includeTemplate "command-manifest.tmpl" . }}' >"$manifest_include"
for os in linux darwin; do
  rendered="$scratch/manifest-$os.json"
  render "$repo_root" "$scratch" "$chezmoi_bin" "$os" "$manifest_include" "$rendered"
  [[ -s $rendered ]] || fail "the command manifest rendered empty for $os"
  declared=$(jq -r '[.units[] | select(.id == "orca-wrapper") | .commands[].name] | join(",")' "$rendered") \
    || fail "the command manifest rendered for $os is not valid JSON"
  if [[ $os == linux ]]; then
    [[ $declared == orca ]] || fail "on linux the orca-wrapper unit declares '$declared', expected 'orca'"
    # The unit's identity is the digest of its source file, so this is what binds the manifest entry
    # to the wrapper every case above exercised. Without it the gate could pass against a unit that
    # ships some other script under the same command name.
    identity=$(jq -r '.units[] | select(.id == "orca-wrapper") | .identity' "$rendered")
    expected_identity=$(sha256sum -- "$wrapper" | cut -d' ' -f1)
    [[ $identity == "$expected_identity" ]] \
      || fail "the orca-wrapper unit's identity does not match $wrapper_source"
  elif [[ -n $declared ]]; then
    fail "the command manifest declares orca on darwin, where the screen reader is not the hazard"
  fi
done

printf 'orca cli shadow gates passed\n'
