#!/bin/sh
set -eu

fail() { printf '%s\n' "Ghostty installation: $*" >&2; exit 1; }
[ "$#" -eq 4 ] || fail 'Expected Ubuntu release, architecture, package URL, and SHA-256.'
release=$1
architecture=$2
package_url=$3
package_sha256=$4
case "$release" in 24.04|26.04) ;; *) fail 'Requires Ubuntu 24.04 or 26.04.' ;; esac
case "$architecture" in amd64|arm64) ;; *) fail 'Requires amd64 or arm64.' ;; esac
[ "$(uname -s)" = Linux ] || fail 'Requires Ubuntu Linux.'
[ -r '/etc/os-release' ] || fail 'Cannot identify the Linux distribution.'
. '/etc/os-release'
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = "$release" ] || fail 'Ubuntu release does not match the selected package.'
[ "$(dpkg --print-architecture)" = "$architecture" ] || fail 'Native architecture does not match the selected package.'

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

if [ "$release" = 26.04 ]; then
    sudo apt-get install -y ghostty
else
    case "$package_url" in https://*) ;; *) fail 'The pinned package URL must use HTTPS.' ;; esac
    [ "${#package_sha256}" -eq 64 ] || fail 'A pinned SHA-256 is required.'
    case "$package_sha256" in *[!0-9a-f]*) fail 'Invalid pinned SHA-256.' ;; esac
    staging=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-ghostty.XXXXXXXX")
    trap 'rm -rf -- "$staging"' EXIT HUP INT TERM
    package="$staging/ghostty.deb"
    curl --fail --location --proto '=https' --tlsv1.2 --output "$package" "$package_url"
    actual_sha256=$(sha256sum "$package" | awk '{print $1}')
    [ "$actual_sha256" = "$package_sha256" ] || fail 'Downloaded package SHA-256 does not match the repository pin.'
    sudo apt-get install -y "$package"
fi
command -v ghostty >/dev/null 2>&1 && ghostty --version >/dev/null 2>&1 || fail 'Installation did not provide a working Ghostty executable.'
printf '%s\n' 'Ghostty and zsh are available.'
