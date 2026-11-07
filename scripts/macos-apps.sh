#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS applications: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon.'
version=$(sw_vers -productVersion)
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.';; esac
[ "$major" -ge 26 ] || fail 'Requires macOS 26 or later.'
[ "$(brew --prefix)" = /opt/homebrew ] || fail 'Requires native Homebrew at /opt/homebrew.'

for item in "$@"; do
    kind=${item%%:*}
    package=${item#*:}
    case "$kind" in formula|cask) ;; *) fail "Unknown application kind: $kind" ;; esac
    if [ "$kind" = cask ]; then
        bundle=
        case "$package" in
            google-chrome) bundle='Google Chrome.app' ;;
            1password) bundle='1Password.app' ;;
            1password-cli) command -v op >/dev/null 2>&1 && continue ;;
            ghostty)
                if [ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ] || [ -x "$HOME/Applications/Ghostty.app/Contents/MacOS/ghostty" ]; then
                    continue
                fi
                ;;
        esac
        if [ -n "$bundle" ] && { [ -d "/Applications/$bundle" ] || [ -d "$HOME/Applications/$bundle" ]; }; then
            continue
        fi
    fi
    if ! brew list "--$kind" --versions "$package" >/dev/null 2>&1; then
        brew install --yes "--$kind" "$package"
    fi
done

brew update
brew upgrade --yes

printf '%s\n' 'macOS applications are available.'
