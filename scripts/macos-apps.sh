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

. "$(dirname "$0")/macos-container-state.sh"

temporary_container_pin=false
restore_container_pin() {
    if [ "$temporary_container_pin" = true ]; then
        brew unpin container || fail 'Cannot restore the container pin; run `brew unpin container` after resolving the Homebrew error.'
        temporary_container_pin=false
    fi
}
trap 'result=$?; trap - 0; restore_container_pin; exit "$result"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Pinning also protects against dependency-driven upgrades. Registration in
# another launchd context is enough to protect its services from post-install.
protect_container() {
    container_protection=false
    container_uid=$(id -u)
    for container_domain in "gui/$container_uid" "user/$container_uid" system; do
        if [ "$container_domain" = system ] && [ "$container_uid" -ne 0 ]; then
            continue
        fi
        if container_services=$(LC_ALL=C launchctl print "$container_domain" 2>&1); then
            case "$container_services" in
                *com.apple.container.*)
                    container_protection=true
                    ;;
            esac
        else
            container_status=$?
            case "$container_domain" in
                gui/*|user/*)
                    container_diagnostic=${container_services#'Bad request.
'}
                    if [ "$container_status" -eq 112 ] && [ "$container_diagnostic" = "Could not find domain for user ${container_domain%/*}: $container_uid" ]; then
                        continue
                    fi
                    ;;
            esac
            fail "Cannot inspect container services in $container_domain; refusing package maintenance."
        fi
    done
    if brew list --formula --versions container >/dev/null 2>&1; then
        container_runtime_state
        if [ "$runtime_state" = running ]; then container_protection=true; fi
        if [ "$container_protection" = true ]; then
            container_pins=$(brew list --pinned) || fail 'Cannot inspect Homebrew pins.'
            case "
$container_pins
" in
                *'
container
'*) ;;
                *)
                    brew pin container || fail 'Cannot protect the active container installation with a Homebrew pin.'
                    temporary_container_pin=true
                    ;;
            esac
        fi
    elif [ "$container_protection" = true ]; then
        fail 'Container services exist without a Homebrew installation; resolve the installation before applying.'
    fi
}

protect_container

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
protect_container
brew upgrade --yes
restore_container_pin

printf '%s\n' 'macOS applications are available.'
