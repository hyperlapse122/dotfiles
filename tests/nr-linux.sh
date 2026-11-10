#!/usr/bin/env bash
# Tests for scripts/nr-linux, the apply helper on a non-NixOS host. Every run
# uses NR_ROOT to point /etc and /usr at a fixture tree and NR_DRY_RUN to
# print the resolved commands; nothing is built, activated, or run as root.
set -euo pipefail

script=${1:-}
if [[ $# -ne 1 || -z $script || ! -f $script ]]; then
  printf 'usage: %s NR_LINUX_SCRIPT\n' "${0##*/}" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/nr-linux-tests.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

fail() { printf 'nr-linux: FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'nr-linux: ok - %s\n' "$*"; }

git_bin=$(command -v git) || fail 'git is required'
rendered=$scratch/nr
sed -e "s|@GIT@|$git_bin|" "$script" >"$rendered"
chmod +x "$rendered"

user=$(id -un)
export HOME=$scratch/home
mkdir -p "$HOME/.config/nix-config/age"
export NR_DRY_RUN=1

repo=$scratch/repo
mkdir -p "$repo"
"$git_bin" -C "$repo" init -q
printf '{}\n' >"$repo/flake.nix"

# A fixture root where every distribution prerequisite holds except the setuid
# bit on the uidmap helpers, which a build sandbox cannot set.
root=$scratch/root
mkdir -p "$root/etc" "$root/usr/bin" "$root/lib/systemd/system"
printf '%s:100000:65536\n' "$user" >"$root/etc/subuid"
printf '%s:100000:65536\n' "$user" >"$root/etc/subgid"
printf '%s:x:1001:\n' "$user" >"$root/etc/group"
printf '/bin/sh\n%s/.nix-profile/bin/zsh\n' "$HOME" >"$root/etc/shells"
printf 'host=fixturehost\nvariant=bootstrap\n' >"$root/etc/nix-config-host"
touch "$root/usr/bin/newuidmap" "$root/usr/bin/newgidmap"
export NR_ROOT=$root

run() { "$rendered" "$@" --flake-dir "$repo"; }

# --- host resolution ---------------------------------------------------------

out=$(run build 2>&1) || fail "build with a marker failed: $out"
[[ $out == *"$repo#systemConfigs.fixturehost "* || $out == *"$repo#systemConfigs.fixturehost"$'\n'* ]] ||
  fail "build did not take the host from the marker: $out"
[[ $out == *"$repo#homeConfigurations.fixturehost.activationPackage"* ]] ||
  fail "build did not resolve the Home Manager output: $out"
pass 'build takes the host from /etc/nix-config-host, never from uname'

out=$(run build --host other --bootstrap 2>&1) || fail "build --host --bootstrap failed: $out"
[[ $out == *"#systemConfigs.other-bootstrap"* && $out == *"#homeConfigurations.other-bootstrap.activationPackage"* ]] ||
  fail "--host and --bootstrap did not select the bootstrap outputs: $out"
pass '--host overrides the marker and --bootstrap selects the bootstrap outputs'

mv "$root/etc/nix-config-host" "$scratch/marker"
if out=$(run build 2>&1); then fail "build without a marker or --host succeeded: $out"; fi
[[ $out == *--host* ]] || fail "the missing host is not explained: $out"
[[ $out != *"nix build"* ]] || fail "nr built something before naming the host: $out"
pass 'without a marker, nr requires --host before building anything'
mv "$scratch/marker" "$root/etc/nix-config-host"

# system-manager also creates /run/current-system; the marker alone decides.
mkdir -p "$root/run/current-system"
out=$(run build 2>&1) || fail "a present /run/current-system changed the mode: $out"
[[ $out == *"#systemConfigs.fixturehost"* ]] || fail "unexpected resolution beside /run/current-system: $out"
pass 'a /run/current-system beside the marker does not change the mode'

for sub in boot test; do
  if out=$(run "$sub" 2>&1); then fail "$sub succeeded on a non-NixOS host"; fi
  [[ $out == *"nr switch"* ]] || fail "$sub does not point at nr switch: $out"
done
pass 'boot and test refuse and point at nr switch'

# --- preflight ---------------------------------------------------------------

expect_refusal() {
  local label=$1 needle=$2
  shift 2
  if out=$(run switch "$@" 2>&1); then fail "$label: switch succeeded"; fi
  [[ $out == *"$needle"* ]] || fail "$label: the refusal does not name $needle: $out"
  [[ $out != *"nix build"* && $out != *register-profile* ]] ||
    fail "$label: nr went on to build or activate: $out"
}

mv "$root/etc/subuid" "$scratch/subuid"
expect_refusal 'missing subuid range' 'usermod --add-subuids'
mv "$scratch/subuid" "$root/etc/subuid"
mv "$root/etc/subgid" "$scratch/subgid"
expect_refusal 'missing subgid range' 'usermod --add-subgids'
mv "$scratch/subgid" "$root/etc/subgid"
pass 'a missing subordinate id range stops nr before it builds'

mv "$root/etc/group" "$scratch/group"
expect_refusal 'missing private group' 'groupadd'
mv "$scratch/group" "$root/etc/group"
pass 'a missing private group, which the pcscd socket needs, stops nr before it builds'

touch "$root/lib/systemd/system/pcscd.service"
expect_refusal 'distribution pcscd' 'apt remove pcscd'
rm "$root/lib/systemd/system/pcscd.service"
pass "the distribution's pcscd stops nr before it builds"

printf '/bin/sh\n' >"$root/etc/shells"
expect_refusal 'unregistered zsh' '/etc/shells'
printf '/bin/sh\n%s/.nix-profile/bin/zsh\n' "$HOME" >"$root/etc/shells"
pass 'an unregistered managed zsh stops nr before it builds'

expect_refusal 'production without an identity' 'recover-age-identity --user --host fixturehost'
pass 'production without an identity stops nr before it builds'

# Bootstrap needs no identity: without one it gets past that check and stops
# only at the uidmap helpers, the last preflight item the sandbox cannot meet.
expect_refusal 'bootstrap without an identity' 'apt install uidmap' --bootstrap
pass 'bootstrap does not require an identity'

touch "$HOME/.config/nix-config/age/key.txt"
expect_refusal 'uidmap without setuid' 'apt install uidmap'
expect_refusal 'uidmap without setuid, bootstrap' 'apt install uidmap' --bootstrap
pass 'uidmap helpers without the setuid bit stop nr before it builds'

# --- activation with prebuilt paths ------------------------------------------
# Every preflight item above held except the setuid bit, so build alone is
# the only subcommand that reaches the prebuilt-path branch here.

out=$(NR_SYSTEM_OUT=/nix/store/fake-system NR_HOME_OUT=/nix/store/fake-home run build 2>&1) ||
  fail "build with prebuilt paths failed: $out"
[[ $out != *"nix build"* ]] || fail "prebuilt paths still ran nix build: $out"
pass 'prebuilt store paths skip the build'

printf 'nr-linux: all tests passed\n'
