#!/bin/sh
set -eu

fail() { printf '%s\n' "Terminal environment ERROR: $*" >&2; exit 1; }
pending=0
note_pending() { pending=1; printf '%s\n' "Terminal environment PENDING: $*" >&2; }
[ "$#" -eq 7 ] || fail 'Expected mode, OS, architecture, release, home, Swift helper, and configuration template.'
mode=$1 os=$2 architecture=$3 release=$4 home=$5 swift_helper=$6 configuration=$7
case "$mode" in apply|status) ;; *) fail 'Mode must be apply or status.' ;; esac
case "$os:$architecture:$release" in linux:amd64:26.04|darwin:arm64:26) ;; *) fail 'Unsupported terminal platform.' ;; esac
[ -r "$configuration" ] || fail 'Managed Ghostty configuration template is missing.'
uid=$(id -u)
[ "$uid" != 0 ] || fail 'Run as the intended non-root user; elevate only native package commands.'
user=$(id -un)

if [ "$os" = linux ]; then
    python3 "$(dirname "$0")/linux-platform.py" || fail 'Unsupported Ubuntu Desktop host; see the host probe blockers.'
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
    command -v xdg-terminal-exec >/dev/null 2>&1 || fail 'Ubuntu default-terminal dispatcher xdg-terminal-exec is missing.'
    desktop_id=$(python3 - "$ghostty" "$home" <<'PYTHON'
import configparser
import os
from pathlib import Path
import shlex
import shutil
import sys

binary, home = sys.argv[1:]
roots = [os.environ.get('XDG_DATA_HOME', home + '/.local/share')]
roots += os.environ.get('XDG_DATA_DIRS', '/usr/local/share:/usr/share:/var/lib/snapd/desktop').split(':')
seen = set()
for root in roots:
    for desktop_id in ('com.mitchellh.ghostty.desktop', 'ghostty_ghostty.desktop'):
        if desktop_id in seen:
            continue
        entry = Path(root) / 'applications' / desktop_id
        if not entry.is_file():
            continue
        seen.add(desktop_id)
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        parser.read(entry, encoding='utf-8')
        if not parser.has_section('Desktop Entry'):
            continue
        fields = parser['Desktop Entry']
        if fields.get('Type') != 'Application' or fields.get('Hidden', '').lower() == 'true':
            continue
        command = fields.get('Exec', '')
        parts = shlex.split(command)
        if parts and Path(parts[0]).name == 'env':
            parts.pop(0)
            while parts and '=' in parts[0]:
                parts.pop(0)
        executable = shutil.which(parts[0]) if parts else None
        if executable and os.path.realpath(executable) == os.path.realpath(binary):
            print(desktop_id)
            sys.exit(0)
sys.exit('No installed Ghostty desktop entry matches the active executable.')
PYTHON
    ) || fail 'Cannot establish the installed Ghostty desktop entry.'
    list="$config_home/ubuntu-xdg-terminals.list"
    if [ "$mode" = apply ]; then
        temporary=$(mktemp "$config_home/.ghostty-terminals.XXXXXXXX") || fail 'Cannot stage the terminal preference list.'
        { printf '%s\n' "$desktop_id"
          if [ -f "$list" ]; then grep -Fvx "$desktop_id" "$list" || [ "$?" -eq 1 ]; fi
        } > "$temporary" || { rm -f "$temporary"; fail 'Cannot read the existing terminal preference list.'; }
        if cmp -s "$temporary" "$list"; then
            rm -f "$temporary"
        else
            mv "$temporary" "$list" || fail 'Cannot write the terminal preference list.'
        fi
    fi
    selected_id=$(XTE_CACHE_ENABLED=0 xdg-terminal-exec --print-id) || fail 'Cannot inspect the effective desktop terminal.'
    if [ "$selected_id" != "$desktop_id" ]; then
        note_pending 'The desktop dispatcher does not select the installed Ghostty entry; check the Ubuntu GNOME session and apply again.'
    fi
    note_pending 'Native GNOME acceptance remains unverified: check Ctrl+Alt+T, the Files terminal action, and a Terminal=true launcher in a fresh desktop session.'
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
