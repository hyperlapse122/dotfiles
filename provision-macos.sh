#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS provisioning: $*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail 'Usage: provision-macos.sh'
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon (arm64).'
translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')
[ "$translated" != 1 ] || fail 'Run from a native terminal, not Rosetta.'
version=$(sw_vers -productVersion)
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.' ;; esac
[ "$major" -ge 15 ] || fail 'Requires macOS 15 or later.'
[ "$(id -u)" -ne 0 ] || fail 'Run as a normal user, not root; approve installer prompts when requested.'
xcode-select -p >/dev/null 2>&1 || fail 'Install Command Line Tools with xcode-select --install, then rerun.'
xcrun --find clang >/dev/null 2>&1 || fail 'Select a usable Apple compiler with xcode-select.'

existing_brew=$(command -v brew || true)
if [ -n "$existing_brew" ]; then
    [ "$("$existing_brew" --prefix)" = '/opt/homebrew' ] || fail 'Requires native Homebrew at /opt/homebrew; resolve the existing installation manually.'
fi
brew='/opt/homebrew/bin/brew'
if [ ! -x "$brew" ]; then
    installer=$(mktemp "${TMPDIR:-/tmp}/dotfiles-homebrew.XXXXXX")
    trap 'rm -f "$installer"' 0
    trap 'exit 1' 1 2 15
    curl -fsSL --output "$installer" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
    /bin/bash "$installer"
fi
[ -x "$brew" ] || fail 'The Homebrew installer did not provide /opt/homebrew/bin/brew.'
[ "$("$brew" --prefix)" = '/opt/homebrew' ] || fail 'Requires native Homebrew at /opt/homebrew.'
shellenv=$("$brew" shellenv)
eval "$shellenv"

for package in git mise chezmoi gnupg pinentry-mac; do
    if ! "$brew" list --formula --versions "$package" >/dev/null 2>&1; then
        "$brew" install --formula "$package"
    fi
done
for pair in git:git mise:mise chezmoi:chezmoi gnupg:gpg gnupg:gpgconf pinentry-mac:pinentry-mac; do
    package=${pair%%:*}
    executable=${pair#*:}
    prefix=$("$brew" --prefix "$package")
    [ -x "$prefix/bin/$executable" ] || fail "Missing $executable from Homebrew $package; repair the package and rerun."
done

printf '%s\n' 'Prerequisites ready. No checkout was initialized and no personal settings were applied.'
printf '%s\n' 'Activate Homebrew in your shell: eval "$(/opt/homebrew/bin/brew shellenv)"'
printf '%s\n' 'Continue with the bootstrap.sh download and checkout preparation in docs/setup/macos.md.'
