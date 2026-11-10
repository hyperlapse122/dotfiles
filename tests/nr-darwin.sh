#!/usr/bin/env bash
# Tests for scripts/nr-darwin, the apply helper on a macOS host. Every run uses
# NR_ROOT to point /etc at a fixture tree and puts logging stubs of nix,
# nix-env, and sudo first on PATH, so nothing is built, activated, or run as
# root.
set -euo pipefail

script=${1:-}
if [[ $# -ne 1 || -z $script || ! -f $script ]]; then
  printf 'usage: %s NR_DARWIN_SCRIPT\n' "${0##*/}" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/nr-darwin-tests.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'nr-darwin: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'nr-darwin: ok - %s\n' "$*"; }

git_bin=$(command -v git) || fail 'git is required'
# The stubs run in a build sandbox, which has no /usr/bin/env.
bash_bin=$(command -v bash)

export HOME=$scratch/home
identity=$HOME/.config/nix-config/age/key.txt
mkdir -p "${identity%/*}"

repo=$scratch/repo
mkdir -p "$repo"
"$git_bin" -C "$repo" init -q
printf '{}\n' >"$repo/flake.nix"

root=$scratch/root
mkdir -p "$root/etc"
marker=$root/etc/nix-config-host
export NR_ROOT=$root

# Stubs that record each call, one line per call, in $log. The built system
# is a directory whose activate stub records itself the same way.
log=$scratch/calls
stubs=$scratch/bin
system_out=$scratch/store/darwin-system
mkdir -p "$stubs" "$system_out"
cat >"$stubs/nix" <<EOF
#!$bash_bin
printf 'nix %s\n' "\$*" >>"$log"
printf '%s\n' "$system_out"
EOF
cat >"$stubs/nix-env" <<EOF
#!$bash_bin
printf 'nix-env %s\n' "\$*" >>"$log"
EOF
cat >"$stubs/sudo" <<EOF
#!$bash_bin
printf 'sudo %s\n' "\$*" >>"$log"
[[ \$1 == -v ]] && exit 0
[[ \$1 == -- ]] && shift
exec "\$@"
EOF
cat >"$system_out/activate" <<EOF
#!$bash_bin
printf 'activate %s\n' "\$0" >>"$log"
EOF
chmod +x "$stubs/nix" "$stubs/nix-env" "$stubs/sudo" "$system_out/activate"
export PATH=$stubs:$PATH

run() { : >"$log"; "$script" "$@" --flake-dir "$repo"; }
apply() { : >"$log"; "$script" "$@" --flake-dir "$repo"; }

printf 'host=fixturehost\nvariant=production\n' >"$marker"

# --- host resolution ---------------------------------------------------------

run build >/dev/null 2>&1 || fail "build with a marker failed: $(cat "$log")"
[[ $(<"$log") == "nix build --no-link --print-out-paths $repo#darwinConfigurations.fixturehost.system" ]] ||
  fail "build did not resolve the darwin system of the marker's host: $(cat "$log")"
pass 'build takes the host from /etc/nix-config-host and builds darwinConfigurations.<host>.system'

run build --host other --bootstrap >/dev/null 2>&1 || fail "build --host --bootstrap failed: $(cat "$log")"
[[ $(<"$log") == *"#darwinConfigurations.other-bootstrap.system" ]] ||
  fail "--host and --bootstrap did not select the bootstrap output: $(cat "$log")"
pass '--host overrides the marker and --bootstrap selects the bootstrap output'

mv "$marker" "$scratch/marker"
if out=$(run build 2>&1); then fail "build without a marker or --host succeeded: $out"; fi
[[ $out == *--host* ]] || fail "the missing host is not explained: $out"
[[ ! -s $log ]] || fail "nr built something before naming the host: $(cat "$log")"
pass 'without a marker, nr requires --host before building anything'
mv "$scratch/marker" "$marker"

# --- subcommands -------------------------------------------------------------

for sub in boot test; do
  if out=$(run "$sub" 2>&1); then fail "$sub succeeded on a macOS host"; fi
  [[ $out == *"nr switch"* ]] || fail "$sub does not point at nr switch: $out"
done
pass 'boot and test refuse and point at nr switch'

set +e
out=$(run frobnicate 2>&1)
status=$?
set -e
[[ $status -ne 0 ]] || fail "an unknown subcommand succeeded: $out"
[[ $out == *"unknown subcommand frobnicate"* && $out == *"usage: nr"* ]] ||
  fail "an unknown subcommand did not print usage: $out"
pass 'an unknown subcommand prints usage and exits non-zero'

# --- preflight ---------------------------------------------------------------

expect_refusal() {
  local label=$1 needle=$2
  shift 2
  if out=$(run switch "$@" 2>&1); then fail "$label: switch succeeded: $out"; fi
  [[ $out == *"$needle"* ]] || fail "$label: the refusal does not name $needle: $out"
  [[ ! -s $log ]] ||
    fail "$label: nr went on to build or activate: $(cat "$log")"
}

expect_refusal 'production without an identity' "$identity"
expect_refusal 'production without an identity, recovery hint' 'recover-age-identity --user --host fixturehost'
pass 'production without an identity stops nr before it builds and names the file'

run switch --bootstrap >/dev/null 2>&1 || fail "bootstrap without an identity was refused: $(cat "$log")"
pass 'bootstrap does not require an identity'

touch "$identity"

printf 'host=fixturehost\nvariant=bootstrap\n' >"$marker"
expect_refusal 'production switch from a bootstrap marker' '--host fixturehost'
run switch --host fixturehost >/dev/null 2>&1 || fail "--host did not allow the move to production: $(cat "$log")"
[[ $(head -n1 "$log") == *"#darwinConfigurations.fixturehost.system" ]] || fail "--host did not target production: $(cat "$log")"
run switch --bootstrap >/dev/null 2>&1 || fail "--bootstrap from a bootstrap marker was refused: $(cat "$log")"
[[ $(head -n1 "$log") == *"#darwinConfigurations.fixturehost-bootstrap.system" ]] ||
  fail "--bootstrap did not target the bootstrap output: $(cat "$log")"
run build >/dev/null 2>&1 || fail "build from a bootstrap marker was refused: $(cat "$log")"
pass 'a bootstrap marker refuses a production switch unless --host or --bootstrap asks for it'
printf 'host=fixturehost\nvariant=production\n' >"$marker"

# --- apply order -------------------------------------------------------------

profile=/nix/var/nix/profiles/system
nix_env=$stubs/nix-env

apply switch >/dev/null 2>&1 || fail "switch with stubs failed: $(cat "$log")"
expected="nix build --no-link --print-out-paths $repo#darwinConfigurations.fixturehost.system
sudo -v
sudo -- $nix_env -p $profile --set $system_out
nix-env -p $profile --set $system_out
sudo -- $system_out/activate
activate $system_out/activate"
[[ $(<"$log") == "$expected" ]] || fail "switch ran the wrong sequence: $(cat "$log")"
pass 'switch builds once, registers the system profile under sudo, then activates under sudo'

apply switch --bootstrap >/dev/null 2>&1 || fail "switch --bootstrap with stubs failed: $(cat "$log")"
[[ $(head -n1 "$log") == *"#darwinConfigurations.fixturehost-bootstrap.system" ]] ||
  fail "switch --bootstrap did not build the bootstrap output: $(cat "$log")"
grep -q "activate $system_out/activate" "$log" || fail "switch --bootstrap did not activate: $(cat "$log")"
pass 'switch --bootstrap targets <host>-bootstrap'

apply build >/dev/null 2>&1 || fail "build with stubs failed: $(cat "$log")"
[[ $(<"$log") == "nix build --no-link --print-out-paths $repo#darwinConfigurations.fixturehost.system" ]] ||
  fail "build did more than build: $(cat "$log")"
pass 'build builds the system and activates nothing'

printf 'nr-darwin: all tests passed\n'
