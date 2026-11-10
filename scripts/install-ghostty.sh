#!/bin/sh
set -eu

fail() { printf '%s\n' "Ghostty installation: $*" >&2; exit 1; }
python3 "$(dirname "$0")/linux-platform.py" || fail 'Unsupported Fedora KDE Plasma Desktop host; see the host probe blockers.'

has_system_zsh() {
    for shell in '/bin/zsh' '/usr/bin/zsh'; do
        if [ -x "$shell" ] && "$shell" --version >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}
if ! has_system_zsh; then
    sudo dnf install -y zsh
fi
has_system_zsh || fail 'Installation did not provide a working system zsh executable.'

if command -v ghostty >/dev/null 2>&1 && ghostty --version >/dev/null 2>&1; then
    printf '%s\n' 'Ghostty and zsh are available.'
    exit 0
fi
fail 'Ghostty is not installed. The package step installs it from the ghostty repository declared in home/.chezmoidata/linux.yaml; check that the repository has a build for this Fedora release and apply again.'
