#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS applications: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon.'
version=$(sw_vers -productVersion)
major=${version%%.*}
case "$major" in ''|*[!0-9]*) fail 'Cannot identify the macOS version.';; esac
[ "$major" -ge 15 ] || fail 'Requires macOS 15 or later.'
[ "$(brew --prefix)" = /opt/homebrew ] || fail 'Requires native Homebrew at /opt/homebrew.'

# An external/bundled engine is retained; never layer Homebrew Podman over it.
podman=$(command -v podman || true)
if [ -x '/opt/podman/bin/podman' ]; then
    podman='/opt/podman/bin/podman'
    if brew list --formula --versions podman >/dev/null 2>&1; then
        fail 'Both bundled and Homebrew Podman are installed. Select one engine manually, then reapply.'
    fi
fi
if [ -z "$podman" ]; then
    if ! brew list --formula --versions podman >/dev/null 2>&1; then
        brew install --formula podman
    fi
    podman="$(brew --prefix podman)/bin/podman"
    [ -x "$podman" ] || fail 'The Homebrew Podman executable is missing.'
fi

for item in "$@"; do
    kind=${item%%:*}
    package=${item#*:}
    case "$kind" in formula|cask) ;; *) fail "Unknown application kind: $kind" ;; esac
    if [ "$kind" = cask ]; then
        bundle=
        case "$package" in
            google-chrome) bundle='Google Chrome.app' ;;
            1password) bundle='1Password.app' ;;
            podman-desktop) bundle='Podman Desktop.app' ;;
            1password-cli) command -v op >/dev/null 2>&1 && continue ;;
        esac
        if [ -n "$bundle" ] && { [ -d "/Applications/$bundle" ] || [ -d "$HOME/Applications/$bundle" ]; }; then
            continue
        fi
    fi
    if ! brew list "--$kind" --versions "$package" >/dev/null 2>&1; then
        brew install "--$kind" "$package"
    fi
done

machines=$("$podman" machine list --format '{{.Name}}|{{.Running}}|{{.Default}}')
if [ -z "$machines" ]; then
    "$podman" machine init
    "$podman" machine start
else
    running=$(printf '%s\n' "$machines" | awk -F '|' '$2 == "true" { print $1; exit }')
    if [ -z "$running" ]; then
        selected=$(printf '%s\n' "$machines" | awk -F '|' '$3 == "true" { print $1; exit }')
        if [ -z "$selected" ]; then
            count=$(printf '%s\n' "$machines" | wc -l | tr -d ' ')
            [ "$count" = 1 ] || fail 'Multiple stopped Podman machines have no default. Start the intended machine, then reapply.'
            selected=${machines%%|*}
        fi
        "$podman" machine start "$selected"
    fi
fi
"$podman" info --format '{{.Host.Arch}}' >/dev/null
printf '%s\n' 'macOS applications and the existing/default Podman machine are available.'
