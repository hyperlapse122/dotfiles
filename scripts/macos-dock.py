"""Reconcile the owned Dock preferences during explicit chezmoi application."""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
from urllib.parse import unquote, urlparse


class Defaults:
    def __init__(self, domain='com.apple.dock'):
        self.domain = domain

    def read(self):
        result = subprocess.run(['/usr/bin/defaults', 'export', self.domain, '-'], capture_output=True)
        if result.returncode:
            error = result.stderr.decode(errors='replace')
            if 'does not exist' in error or 'not found' in error:
                return {}
            raise RuntimeError(f'Cannot read Dock preferences: {error.strip()}')
        return plistlib.loads(result.stdout)

    def write(self, key, value):
        # A plist value lets defaults preserve array/dictionary types and Unicode.
        xml = plistlib.dumps(value).decode()
        result = subprocess.run(['/usr/bin/defaults', 'write', self.domain, key, xml],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f'Cannot write Dock preference {key}: {result.stderr.strip()}')


def tile_path(tile):
    url = tile.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '')
    parsed = urlparse(url)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        return None
    return Path(unquote(parsed.path))


def make_tile(path, folder=False):
    return {'tile-type': 'directory-tile' if folder else 'file-tile',
            'tile-data': {'file-data': {'_CFURLString': path.as_uri(), '_CFURLStringType': 15},
                          'file-type': 2 if folder else 41}}


def retained_tiles(paths, existing, folder=False):
    tiles = {tile_path(tile): tile for tile in existing}
    return [tiles.get(path) or make_tile(path, folder=folder) for path in paths]


def restart_dock():
    # Only the applying user's Dock may be restarted. No running Dock is normal over SSH.
    result = subprocess.run(['/usr/bin/killall', '-u', str(os.getuid()), 'Dock'],
                            capture_output=True, text=True)
    if result.returncode and 'No matching processes' not in result.stderr:
        raise RuntimeError(f'Cannot restart Dock: {result.stderr.strip()}')


def reconcile(settings, home, preferences, *, roots=None, restart=restart_dock):
    roots = roots if roots is not None else [Path('/Applications'), home / 'Applications',
                                           Path('/System/Applications')]
    paths = []
    for group in ('common', 'personal', 'work', 'developmentAI'):
        for candidates in settings['groups'][group]:
            app = next((root / name for name in candidates for root in roots
                        if (root / name).is_dir()), None)
            if app is not None and app not in paths:
                paths.append(app)
    current = preferences.read()
    desired = {
        'tilesize': settings['tilesize'],
        'show-recents': settings['showRecents'],
        'persistent-apps': retained_tiles(paths, current.get('persistent-apps', [])),
        'persistent-others': retained_tiles([home / 'Downloads'], current.get('persistent-others', []), folder=True),
    }
    changed = False
    for key, value in desired.items():
        if current.get(key) != value or type(current.get(key)) is not type(value):
            preferences.write(key, value)
            changed = True
    if changed:
        restart()
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings', required=True, help='Rendered macosDock JSON configuration')
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        return 0
    if int(platform.mac_ver()[0].split('.')[0]) < 26:
        parser.exit(1, 'Dock management requires macOS 26 or later.\n')
    try:
        changed = reconcile(json.loads(args.settings), args.destination.resolve(), Defaults())
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'Dock configuration failed: {error}\n')
    print('Dock preferences updated.' if changed else 'Dock preferences already match.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
