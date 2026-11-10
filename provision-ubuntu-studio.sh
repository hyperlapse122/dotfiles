#!/bin/sh
set -eu

fail() { printf '%s\n' "Ubuntu Studio provisioning: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: provision-ubuntu-studio.sh [inspected-checkout]'
source=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"}
[ -f "$source/.chezmoiroot" ] && [ -f "$source/mise.toml" ] && [ -f "$source/scripts/linux-platform.py" ] ||
    fail 'Run from an inspected checkout containing .chezmoiroot, mise.toml and scripts/linux-platform.py; a standalone download is insufficient.'
command -v python3 >/dev/null 2>&1 || fail 'Ubuntu Studio system python3 is required for host inspection; restore it manually before provisioning.'
python3 "$source/scripts/linux-platform.py" || fail 'Host prerequisites failed; no packages or personal settings were changed.'
[ "$(id -u)" -ne 0 ] || fail 'Run as a normal user with sudo access, not root.'
for command in sudo apt-get dpkg-query; do
    command -v "$command" >/dev/null 2>&1 || fail "Requires $command from the installed Ubuntu Studio system."
done

# Bootstrap tools only. Application and native build packages belong to explicit apply.
missing=''
for package in ca-certificates curl git xz-utils bzip2 unzip; do
    if [ "$(dpkg-query -W '-f=${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]; then
        missing="$missing $package"
    fi
done
if ! command -v mise >/dev/null 2>&1; then
    if [ "$(dpkg-query -W '-f=${Status}' extrepo 2>/dev/null || true)" != 'install ok installed' ]; then
        missing="$missing extrepo"
    fi
fi
if [ -n "$missing" ]; then
    sudo apt-get update
    # Package names above are fixed repository literals.
    # shellcheck disable=SC2086
    sudo apt-get install -y $missing
fi
if ! command -v mise >/dev/null 2>&1; then
    sudo extrepo enable mise
    sudo apt-get update
    sudo apt-get install -y mise
fi
for command in git curl mise; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing $command after provisioning; repair the package and rerun."
done
printf '%s\n' 'Prerequisites ready. No worktree preparation, personal application or runtime action was performed.'
printf '%s\n' 'Prepare the permanent checkout with bootstrap-ubuntu-studio.sh, then register and apply explicitly.'
