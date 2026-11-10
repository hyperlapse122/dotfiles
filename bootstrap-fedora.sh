#!/bin/sh
set -eu

fail() { printf '%s\n' "Fedora bootstrap: $*" >&2; exit 1; }
[ "$#" -le 1 ] || fail 'Usage: bootstrap-fedora.sh [permanent-checkout]'
source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -f "$source/scripts/linux-platform.py" ] || fail 'Run this entry point from an inspected checkout with scripts/linux-platform.py; a standalone download is insufficient.'
command -v python3 >/dev/null 2>&1 || fail 'Requires Fedora system python3; run provision-fedora.sh from an inspected checkout.'
python3 "$source/scripts/linux-platform.py" || fail 'Host prerequisites failed; no checkout or personal settings were changed.'
for command in git mise; do
    command -v "$command" >/dev/null 2>&1 || fail "Install $command with provision-fedora.sh before bootstrap."
done

destination=${1:-"$HOME/src/github.com/hyperlapse122/dotfiles"}
repository=https://github.com/hyperlapse122/dotfiles.git
if [ ! -d "$destination" ] || [ -z "$(ls -A "$destination")" ]; then
    git clone -- "$repository" "$destination"
fi
[ -d "$destination/.git" ] || fail 'Destination must be a permanent standalone checkout.'
[ -z "$(git -C "$destination" rev-parse --show-prefix)" ] || fail 'Destination must be the repository root.'
origin=$(git -C "$destination" config --get remote.origin.url)
[ "${origin%/}" = "$repository" ] || fail 'Destination origin is not the dotfiles repository; select another destination.'
[ -f "$destination/mise.toml" ] || fail 'Destination has no mise.toml.'
[ -f "$destination/.chezmoi-bootstrap.toml" ] || fail 'Destination has no hook-free bootstrap config.'
cd "$destination"
destination=$(pwd -P)
mise trust "$destination/mise.toml"
mise install
# Install can report postinstall failures as warnings; require the task to pass.
mise run bootstrap
printf '%s\n' "Prepared: $destination" 'No personal settings were applied and no global source was registered.'
printf 'Register explicitly next: mise --cd "%s" exec -- chezmoi --source "%s" init\n' "$destination" "$destination"
