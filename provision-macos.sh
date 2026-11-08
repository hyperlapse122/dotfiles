#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS provisioning: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: provision-macos.sh [source-root]'
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon (arm64).'
translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')
[ "$translated" != 1 ] || fail 'Run from a native terminal, not Rosetta.'
version=$(sw_vers -productVersion)
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.' ;; esac
[ "$major" -ge 26 ] || fail 'Requires macOS 26 or later.'
[ "$(id -u)" -ne 0 ] || fail 'Run as a normal user, not root; pre-authorize sudo if the Homebrew installer needs it.'
scratch=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-macos.XXXXXX")
trap 'rm -rf "$scratch"' 0
trap 'exit 1' 1 2 15

existing_brew=$(command -v brew || true)
if [ -n "$existing_brew" ]; then
    [ "$("$existing_brew" --prefix)" = '/opt/homebrew' ] || fail 'Requires native Homebrew at /opt/homebrew; resolve the existing installation manually.'
fi
brew='/opt/homebrew/bin/brew'
if [ ! -x "$brew" ]; then
    package="$scratch/Homebrew.pkg"
    curl -fsSL --output "$package" https://github.com/Homebrew/brew/releases/download/7.0.12/Homebrew.pkg
    digest=$(shasum -a 256 "$package")
    [ "${digest%% *}" = a9825310dce8d94bc97f70140700089183c3a894b1048501d933865d7c2441bd ] || fail 'Homebrew package checksum mismatch.'
    pkgutil --check-signature "$package" >/dev/null || fail 'Homebrew package signature verification failed.'
    sudo installer -pkg "$package" -target /
fi
[ -x "$brew" ] || fail 'The Homebrew installer did not provide /opt/homebrew/bin/brew.'
[ "$("$brew" --prefix)" = '/opt/homebrew' ] || fail 'Requires native Homebrew at /opt/homebrew.'
shellenv=$("$brew" shellenv)
eval "$shellenv"

# API-backed bottles work before Apple tools; Git-based auto-update does not.
export HOMEBREW_NO_AUTO_UPDATE=1
for package in mise chezmoi gnupg pinentry-mac; do
    if ! "$brew" list --formula --versions "$package" >/dev/null 2>&1; then
        "$brew" install --yes --formula --force-bottle "$package"
    fi
done
for pair in mise:mise chezmoi:chezmoi gnupg:gpg gnupg:gpgconf pinentry-mac:pinentry-mac; do
    package=${pair%%:*}
    executable=${pair#*:}
    prefix=$("$brew" --prefix "$package")
    [ -x "$prefix/bin/$executable" ] || fail "Missing $executable from Homebrew $package; repair the package and rerun."
done

for command in mise chezmoi; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing $command on PATH after activating Homebrew; inspect brew link $command, then rerun."
done

source=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"}
if [ ! -f "$source/.chezmoiroot" ]; then
    [ "$#" -eq 0 ] || fail 'Source root must contain .chezmoiroot.'
    curl -fsSL --output "$scratch/commit.json" https://api.github.com/repos/hyperlapse122/dotfiles/commits/main
    revision=$(plutil -extract sha raw -o - "$scratch/commit.json")
    case "$revision" in ''|*[!0-9a-f]*) fail 'Cannot resolve the repository commit.' ;; esac
    [ "${#revision}" -eq 40 ] || fail 'Cannot resolve the repository commit.'
    curl -fsSL --output "$scratch/source.tar.gz" "https://codeload.github.com/hyperlapse122/dotfiles/tar.gz/$revision"
    tar -xzf "$scratch/source.tar.gz" -C "$scratch"
    source="$scratch/dotfiles-$revision"
fi
[ -f "$source/mise.toml" ] && [ -f "$source/scripts/macos-xcode.py" ] || fail 'Source snapshot is incomplete.'
mise --cd "$source" trust "$source/mise.toml"
mise --cd "$source" install
mise --cd "$source" run bootstrap
mise --cd "$source" exec -- python "$source/scripts/macos-xcode.py" --source "$source"
xcode-select -p >/dev/null 2>&1 || fail 'Xcode selection is unavailable after provisioning.'
xcrun --find clang >/dev/null 2>&1 || fail 'The selected Xcode compiler is unavailable.'
if ! "$brew" list --formula --versions git >/dev/null 2>&1; then
    "$brew" install --yes --formula --force-bottle git
fi
command -v git >/dev/null 2>&1 || fail 'Git is unavailable after provisioning; repair Homebrew Git.'

printf '%s\n' 'Prerequisites and Xcode ready. No permanent checkout or global chezmoi source was registered.'
printf '%s\n' 'Activate Homebrew in your shell: eval "$(/opt/homebrew/bin/brew shellenv)"'
printf '%s\n' 'Continue with the bootstrap.sh download and checkout preparation in docs/setup/macos.md.'
