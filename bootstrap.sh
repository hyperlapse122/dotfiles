#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS bootstrap: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon (arm64).'
translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')
[ "$translated" != 1 ] || fail 'Run from a native terminal, not Rosetta.'
version=$(sw_vers -productVersion)
[ "${version%%.*}" -ge 26 ] || fail 'Requires macOS 26 or later.'
xcode-select -p >/dev/null 2>&1 || fail 'Install Command Line Tools with xcode-select --install.'
xcrun --find clang >/dev/null 2>&1 || fail 'Select a usable Apple compiler with xcode-select.'
for command in brew git mise; do
    command -v "$command" >/dev/null 2>&1 || fail "Install $command before bootstrap."
done
[ "$(brew --prefix)" = /opt/homebrew ] || fail 'Requires native Homebrew at /opt/homebrew.'
for pair in 'chezmoi:chezmoi' 'gnupg:gpg' 'gnupg:gpgconf' 'pinentry-mac:pinentry-mac'; do
    package=${pair%%:*}
    executable=${pair#*:}
    prefix=$(brew --prefix "$package") || fail "Install $package with Homebrew."
    [ -x "$prefix/bin/$executable" ] || fail "Install $package with Homebrew."
done

[ "$#" -le 1 ] || fail 'Usage: bootstrap.sh [permanent-checkout]'
destination=${1:-"$HOME/src/github.com/hyperlapse122/dotfiles"}
repository=https://github.com/hyperlapse122/dotfiles.git
if [ ! -d "$destination" ] || [ -z "$(ls -A "$destination")" ]; then
    git clone -- "$repository" "$destination"
fi
[ -d "$destination/.git" ] || fail 'Destination must be a permanent standalone checkout.'
[ -z "$(git -C "$destination" rev-parse --show-prefix)" ] || fail 'Destination must be the repository root.'
origin=$(git -C "$destination" config --get remote.origin.url)
[ "${origin%/}" = "$repository" ] || fail 'Destination origin is not the dotfiles repository; select another destination.'
[ -f "$destination/mise.toml" ] || fail 'Destination has no mise.toml.'
cd "$destination"
destination=$(pwd -P)
mise trust "$destination/mise.toml"
mise install
# Install can report postinstall failures as warnings; require the task to pass.
mise run bootstrap
printf '%s\n' "Prepared: $destination" 'No personal settings were applied and no global source was registered.'
printf 'Register explicitly next: sh "%s/configure-chezmoi.sh"\n' "$destination"
