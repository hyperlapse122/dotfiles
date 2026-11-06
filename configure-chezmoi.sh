#!/bin/sh
set -eu

fail() { printf '%s\n' "macOS source registration: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Requires macOS.'
[ "$(uname -m)" = arm64 ] || fail 'Requires native Apple Silicon (arm64).'
translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')
[ "$translated" != 1 ] || fail 'Run from a native terminal, not Rosetta.'
version=$(sw_vers -productVersion)
[ "${version%%.*}" -ge 26 ] || fail 'Requires macOS 26 or later.'
[ "$#" -le 1 ] || fail 'Usage: configure-chezmoi.sh [permanent-checkout]'
source=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"}
[ -d "$source/.git" ] || fail 'Source must be a permanent standalone checkout, not a linked worktree.'
source=$(CDPATH= cd -- "$source" && pwd -P)
[ -z "$(git -C "$source" rev-parse --show-prefix)" ] || fail 'Source must be the repository root.'
origin=$(git -C "$source" config --get remote.origin.url)
[ "${origin%/}" = https://github.com/hyperlapse122/dotfiles.git ] || fail 'Source origin is not the dotfiles repository.'
[ -f "$source/home/.chezmoi.toml.tmpl" ] || fail 'Source has no chezmoi configuration template.'
[ "$(brew --prefix)" = /opt/homebrew ] || fail 'Requires native Homebrew at /opt/homebrew.'
chezmoi="$(brew --prefix chezmoi)/bin/chezmoi"
[ -x "$chezmoi" ] || fail 'Install standalone chezmoi with Homebrew.'

mise --cd "$source" exec python -- python - "$source" "$chezmoi" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tomllib

source = Path(sys.argv[1]).resolve()
chezmoi = sys.argv[2]
home = Path.home()
roots = [Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')]
roots.extend(Path(item) for item in os.environ.get('XDG_CONFIG_DIRS', '/etc/xdg').split(os.pathsep) if item)
config = roots[0] / 'chezmoi' / 'chezmoi.toml'
def resolve(value):
    return Path(os.path.expanduser(value)).resolve()
try:
    for root in roots:
        directory = root / 'chezmoi'
        for suffix in ('json', 'jsonc', 'yaml', 'yml'):
            if (directory / ('chezmoi.' + suffix)).exists():
                raise ValueError('Existing non-TOML configuration requires explicit migration; no configuration was changed.')
        candidate = directory / 'chezmoi.toml'
        if not candidate.exists():
            continue
        data = tomllib.loads(candidate.read_text(encoding='utf-8'))
        default_source = Path(os.environ.get('XDG_DATA_HOME') or home / '.local' / 'share') / 'chezmoi'
        if resolve(data.get('sourceDir', str(default_source))) != source:
            raise ValueError('Existing configuration points to another source; no configuration was changed.')
        if data.get('workingTree') and resolve(data['workingTree']) != source:
            raise ValueError('Existing configuration uses another working tree; no configuration was changed.')
        config = candidate
        break
    subprocess.run([chezmoi, '--config', str(config), '--source', str(source), 'init'], check=True)
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    sys.exit('macOS source registration: ' + str(error))
print('Registered permanent checkout: ' + str(source))
print('No managed home files were applied. Preview changes, then explicitly run mise run apply.')
PY
