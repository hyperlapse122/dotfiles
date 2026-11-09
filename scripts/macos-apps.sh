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

# Homebrew's post-install hook unloads container services. Keep the runtime
# stopped throughout application; these checks cannot prevent a later start.
require_container_stopped() {
    container_uid=$(id -u)
    for container_domain in "gui/$container_uid" "user/$container_uid" system; do
        if [ "$container_domain" = system ] && [ "$container_uid" -ne 0 ]; then
            continue
        fi
        if container_services=$(LC_ALL=C launchctl print "$container_domain" 2>&1); then
            case "$container_services" in
                *com.apple.container.*)
                    fail "Container services are registered in $container_domain. Finish active container tasks before applying and keep the runtime stopped throughout application."
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
}

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
        if [ "$kind:$package" = formula:container ]; then
            require_container_stopped
        fi
        brew install --yes "--$kind" "$package"
    fi
done

brew update
require_container_stopped
brew upgrade --yes

printf '%s\n' 'macOS applications are available.'
