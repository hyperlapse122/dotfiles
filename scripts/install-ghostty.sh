#!/bin/sh
set -eu

fail() { printf '%s\n' "Ghostty installation: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || fail 'Expected Ubuntu release and architecture.'
release=$1 architecture=$2
[ "$release:$architecture" = '26.04:amd64' ] || fail 'Requires Ubuntu Desktop 26.04 amd64.'
python3 "$(dirname "$0")/linux-platform.py" || fail 'Unsupported Ubuntu Desktop host; see the host probe blockers.'

has_system_zsh() {
    for shell in '/bin/zsh' '/usr/bin/zsh'; do
        if [ -x "$shell" ] && "$shell" --version >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}
if ! has_system_zsh; then
    sudo apt-get install -y zsh
fi
has_system_zsh || fail 'Installation did not provide a working system zsh executable.'
if command -v ghostty >/dev/null 2>&1 && ghostty --version >/dev/null 2>&1; then
    printf '%s\n' 'Ghostty is already available; retaining the installed version.'
    exit 0
fi

sudo apt-get install -y ghostty
command -v ghostty >/dev/null 2>&1 && ghostty --version >/dev/null 2>&1 || fail 'Installation did not provide a working Ghostty executable.'
printf '%s\n' 'Ghostty and zsh are available.'
