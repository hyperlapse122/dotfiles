"""Register the repository-pinned native Grok plugin during explicit apply."""

import argparse
import json
import os
from pathlib import Path

import auth_common as common


def apply(destination):
    home = Path(destination)
    binary = home / '.local/bin' / ('grok.exe' if os.name == 'nt' else 'grok')
    plugin = home / '.local/share/dotfiles/harness-plugins/compound-engineering'
    if not (plugin / '.grok-plugin/plugin.json').is_file():
        raise common.AuthError('Pinned native Grok plugin is unavailable.')
    env = dict(os.environ, HOME=str(home), USERPROFILE=str(home),
               GROK_HOME=str(home / '.grok'), GROK_DISABLE_AUTOUPDATER='1')
    def native(*arguments):
        return common.run_private([str(binary), 'plugin', *arguments], env=env, cwd=home,
                                  operation='Cannot reconcile the pinned native Grok plugin.')

    def same_source(value):
        if not isinstance(value, str):
            return False
        try:
            return Path(value).samefile(plugin)
        except OSError:
            return False

    marketplaces = json.loads(native('marketplace', 'list', '--json'))
    installed = json.loads(native('list', '--json'))
    if not isinstance(marketplaces, list) or not isinstance(installed, list):
        raise common.AuthError('Cannot inspect native Grok plugin registration.')
    if not any(entry.get('kind') == 'local' and same_source(entry.get('source', {}).get('path'))
               for entry in marketplaces):
        native('marketplace', 'add', str(plugin))
    managed = [entry for entry in installed if entry.get('name') == 'compound-engineering']
    registered = False
    if len(managed) == 1 and same_source(managed[0].get('source')):
        try:
            registered = Path(managed[0]['path']).samefile(plugin)
        except OSError:
            pass
    if not registered:
        # Native uninstall owns a repository, which may contain other plugins.
        # Check every affected source before replacing any registration.
        if any(other.get('repo_key') == entry['repo_key'] and other.get('name') != 'compound-engineering'
               for entry in managed for other in installed):
            raise common.AuthError('The previous Grok CE source contains unrelated plugins.')
        for _entry in managed:
            native('uninstall', 'compound-engineering')
        native('install', '--trust', str(plugin))
    # Local installs can be links or Windows copies. Grok 1.0.77's native update
    # treats both as live links, so copies need a native reinstall for repair.
    native('enable', 'compound-engineering')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    try:
        apply(args.destination)
    except (common.AuthError, OSError, ValueError):
        raise SystemExit('Grok plugin application failed; private diagnostics withheld.') from None
