#!/bin/sh
set -eu

fail() { printf '%s\n' "Terminal environment ERROR: $*" >&2; exit 1; }
pending=0
note_pending() { pending=1; printf '%s\n' "Terminal environment PENDING: $*" >&2; }
[ "$#" -eq 7 ] || fail 'Expected mode, OS, architecture, release, home, Swift helper, and configuration template.'
mode=$1 os=$2 architecture=$3 release=$4 home=$5 swift_helper=$6 configuration=$7
case "$mode" in apply|status) ;; *) fail 'Mode must be apply or status.' ;; esac
case "$os:$architecture:$release" in linux:amd64:24.04|linux:arm64:24.04|linux:amd64:26.04|linux:arm64:26.04|darwin:arm64:26) ;; *) fail 'Unsupported terminal platform.' ;; esac
[ -r "$configuration" ] || fail 'Managed Ghostty configuration template is missing.'
uid=$(id -u)
[ "$uid" != 0 ] || fail 'Run as the intended non-root user; elevate only native package or alternatives commands.'
user=$(id -un)

if [ "$os" = linux ]; then
    [ "$(uname -s)" = Linux ] || fail 'Expected Ubuntu Linux.'
    [ -r '/etc/os-release' ] || fail 'Cannot identify Ubuntu.'
    . '/etc/os-release'
    [ "$ID" = ubuntu ] && [ "$VERSION_ID" = "$release" ] || fail 'Unsupported Ubuntu release.'
    [ "$(dpkg --print-architecture)" = "$architecture" ] || fail 'Architecture mismatch.'
    record=$(getent passwd "$uid") || fail 'Cannot read the current account.'
    account_home=$(printf '%s\n' "$record" | awk -F: '{print $6}')
    account_shell=$(printf '%s\n' "$record" | awk -F: '{print $7}')
else
    [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon macOS.'
    version=$(sw_vers -productVersion)
    major=${version%%.*}
    case "$major" in ''|*[!0-9]*) fail 'Cannot identify macOS version.' ;; esac
    [ "$major" -ge 26 ] || fail 'Requires macOS 26 or later.'
    account_home=$(dscl . -read "/Users/$user" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //') || fail 'Cannot read the account home.'
    account_shell=$(dscl . -read "/Users/$user" UserShell | sed 's/^UserShell: //') || fail 'Cannot read the account shell.'
fi
[ -d "$home" ] && [ -d "$account_home" ] || fail 'The account home is unavailable.'
[ "$(cd "$home" && pwd -P)" = "$(cd "$account_home" && pwd -P)" ] || fail 'Destination must be the applying account home.'

is_zsh() {
    case "$1" in */zsh) ;; *) return 1 ;; esac
    [ -x "$1" ] && grep -Fqx "$1" '/etc/shells' && "$1" --version >/dev/null 2>&1
}
matches_account_shell() {
    is_zsh "$1" && [ "$1" -ef "$account_shell" ]
}
read_shell() {
    if [ "$os" = linux ]; then
        getent passwd "$uid" | awk -F: '{print $7}'
    else
        dscl . -read "/Users/$user" UserShell | sed 's/^UserShell: //'
    fi
}
if ! is_zsh "$account_shell"; then
    selected=
    for candidate in '/bin/zsh' '/usr/bin/zsh'; do
        if is_zsh "$candidate"; then selected=$candidate; break; fi
    done
    [ -n "$selected" ] || fail 'No executable system zsh is registered in /etc/shells.'
    if [ "$mode" = apply ]; then
        chsh -s "$selected" || fail 'Login-shell change failed; authenticate and apply again.'
        account_shell=$(read_shell) || fail 'Cannot verify the changed account shell.'
        is_zsh "$account_shell" || fail 'The account login shell did not change to zsh.'
        note_pending 'Login shell changed. Log out of all desktop sessions, log in again, and fully restart Ghostty.'
    else
        note_pending 'Account login shell is not zsh; apply the repository configuration.'
    fi
fi

config_home=${XDG_CONFIG_HOME:-$home/.config}
case "$config_home" in /*) ;; *) fail 'XDG_CONFIG_HOME must be absolute.' ;; esac
reconcile_config() {
    directory=$1
    if [ "$mode" = apply ]; then
        mkdir -p "$directory"
        if ! cmp -s "$configuration" "$directory/config.ghostty"; then
            cp "$configuration" "$directory/config.ghostty"
        fi
        if [ -e "$directory/config" ] && ! cmp -s "$configuration" "$directory/config"; then
            cp "$configuration" "$directory/config"
        fi
    else
        if ! cmp -s "$configuration" "$directory/config.ghostty"; then
            note_pending "Managed Ghostty configuration differs at $directory/config.ghostty; apply again."
        fi
        if [ -e "$directory/config" ] && ! cmp -s "$configuration" "$directory/config"; then
            note_pending "Legacy Ghostty configuration overrides defaults at $directory/config; apply again."
        fi
    fi
}
reconcile_config "$config_home/ghostty"
if [ "$os" = darwin ]; then
    reconcile_config "$home/Library/Application Support/com.mitchellh.ghostty"
    [ -r "$swift_helper" ] || fail 'The native macOS association helper is missing.'
    command -v swift >/dev/null 2>&1 || fail 'Install the existing macOS Command Line Tools prerequisite.'
    native_result=0
    swift "$swift_helper" "$mode" "$home" || native_result=$?
    case "$native_result" in
        0) ;;
        2) note_pending 'Complete Ghostty native default-terminal approval in a desktop session, then check status again.' ;;
        *) fail 'Native macOS association operation failed.' ;;
    esac
else
    ghostty=$(command -v ghostty) || fail 'Ghostty is not installed.'
    ghostty --version >/dev/null 2>&1 || fail 'Ghostty executable is not usable.'
    if [ "$release" = 24.04 ]; then
        alternatives=$(update-alternatives --query x-terminal-emulator) || fail 'Cannot inspect the native terminal alternatives.'
        active=$(printf '%s\n' "$alternatives" | sed -n 's/^Value: //p')
        if [ "$active" != "$ghostty" ]; then
            if [ "$mode" = apply ]; then
                if ! printf '%s\n' "$alternatives" | grep -Fqx "Alternative: $ghostty"; then
                    sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator "$ghostty" 50 || fail 'Cannot register Ghostty.'
                fi
                sudo update-alternatives --set x-terminal-emulator "$ghostty" || fail 'Cannot select Ghostty.'
                active=$(update-alternatives --query x-terminal-emulator | sed -n 's/^Value: //p')
                [ "$active" = "$ghostty" ] || fail 'Ghostty is not the effective native terminal alternative.'
            else
                note_pending 'The native terminal alternative is not Ghostty; apply again.'
            fi
        fi
    else
        command -v xdg-terminal-exec >/dev/null 2>&1 || fail 'Ubuntu default-terminal dispatcher xdg-terminal-exec is missing.'
        list="$config_home/ubuntu-xdg-terminals.list"
        if [ "$mode" = apply ]; then
            mkdir -p "$config_home"
            temporary=$(mktemp "$config_home/.ghostty-terminals.XXXXXXXX")
            { printf '%s\n' com.mitchellh.ghostty.desktop
              if [ -f "$list" ]; then grep -Fvx com.mitchellh.ghostty.desktop "$list" || [ "$?" -eq 1 ]; fi
            } > "$temporary"
            if cmp -s "$temporary" "$list"; then rm -f "$temporary"; else mv "$temporary" "$list"; fi
        fi
        selected_id=$(XTE_CACHE_ENABLED=0 xdg-terminal-exec --print-id) || fail 'Cannot inspect the effective desktop terminal.'
        [ "$selected_id" = com.mitchellh.ghostty.desktop ] || note_pending 'The desktop dispatcher does not select Ghostty; check the Ubuntu GNOME session and apply again.'
    fi
    manager_available=1
    manager_environment=$(systemctl --user show-environment 2>/dev/null) || manager_available=0
    if [ "$manager_available" -eq 0 ]; then
        note_pending 'The systemd user-manager environment is unavailable; verify in a desktop session.'
    elif printf '%s\n' "$manager_environment" | grep -q '^SHELL='; then
        manager_shell=$(printf '%s\n' "$manager_environment" | sed -n 's/^SHELL=//p')
        if ! matches_account_shell "$manager_shell"; then
            note_pending 'The systemd user-manager shell is stale. End remaining sessions/linger as needed, then log in again.'
        fi
    fi
fi
if [ "${SHELL+x}" = x ] && ! matches_account_shell "$SHELL"; then
    note_pending 'This session still has a different SHELL. Log out, log in, and fully restart Ghostty.'
fi
if [ "$pending" -eq 1 ]; then
    [ "$mode" = apply ] && exit 0
    exit 2
fi
printf '%s\n' 'Terminal environment READY: Ghostty defaults and zsh account shell are configured.'
