#!/bin/sh
set -eu

fail() { printf '%s\n' "Fedora provisioning: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: provision-fedora.sh [inspected-checkout]'
source=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"}
[ -f "$source/.chezmoiroot" ] && [ -f "$source/mise.toml" ] && [ -f "$source/scripts/linux-platform.py" ] &&
    [ -f "$source/scripts/linux-apps.py" ] && [ -f "$source/home/.chezmoidata/linux.yaml" ] ||
    fail 'Run from an inspected checkout containing .chezmoiroot, mise.toml, scripts/linux-platform.py, scripts/linux-apps.py and home/.chezmoidata/linux.yaml; a standalone download is insufficient.'
command -v python3 >/dev/null 2>&1 || fail 'Fedora system python3 is required for host inspection; restore it manually before provisioning.'
python3 "$source/scripts/linux-platform.py" || fail 'Host prerequisites failed; no packages or personal settings were changed.'
[ "$(id -u)" -ne 0 ] || fail 'Run as a normal user with sudo access, not root.'
for command in sudo dnf rpm; do
    command -v "$command" >/dev/null 2>&1 || fail "Requires $command from the installed Fedora system."
done

# Bootstrap tools only. Application and native build packages belong to explicit apply.
missing=''
for package in ca-certificates curl git gnupg2 xz bzip2 unzip; do
    rpm -q "$package" >/dev/null 2>&1 || missing="$missing $package"
done
if [ -n "$missing" ]; then
    # Package names above are fixed repository literals.
    # shellcheck disable=SC2086
    sudo dnf install -y $missing
fi
if ! command -v mise >/dev/null 2>&1; then
    python3 "$source/scripts/linux-apps.py" --repository mise "$source/home/.chezmoidata/linux.yaml" ||
        fail 'Installing mise from its signed repository failed; resolve the reported problem and rerun.'
fi
for command in git curl mise; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing $command after provisioning; repair the package and rerun."
done
printf '%s\n' 'Prerequisites ready. No worktree preparation, personal application or runtime action was performed.'
printf '%s\n' 'Prepare the permanent checkout with bootstrap-fedora.sh, then register and apply explicitly.'
