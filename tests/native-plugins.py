"""Exercise native plugin activation in a disposable home.

usage: native-plugins.py SCRIPT PLUGINS_JSON [--agy-only] [TEST ...]
PLUGINS_JSON contains plugin, source, and optionally pinned source paths.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

script = Path(sys.argv[1]).read_text()
plugins = json.loads(Path(sys.argv[2]).read_text())
agy_only = '--agy-only' in sys.argv[3:]
sys.argv = [sys.argv[0]] + [arg for arg in sys.argv[3:] if arg != '--agy-only']


class NativePlugins(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        stub = self.home / 'native'
        stub.write_text(f'#!{sys.executable}\n' + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALLS_' + os.path.basename(sys.argv[0]).upper()], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args[-2:] == ['list', '--json']: print('[]')
if os.path.basename(sys.argv[0]) == 'agy': print('agy output: ' + ' '.join(args))
if os.path.basename(sys.argv[0]) == 'agy' and args[:2] == ['plugin', 'install']:
    if os.environ.get('FAIL_INSTALL'): sys.exit(1)
    name = json.loads(os.environ['PLUGIN_NAMES'])[args[2]]
    dest = pathlib.Path(os.environ['HOME']) / '.gemini/config/plugins' / name
    dest.mkdir(parents=True, exist_ok=True)
    (dest / 'plugin.json').write_text('{}')
''')
        stub.chmod(0o755)
        self.script = script
        for cli in ('grok', 'agy'):
            (self.home / cli).symlink_to(stub)
            self.script = re.sub(rf'/nix/store/[^\s]+/bin/{cli}\b', str(self.home / cli), self.script)
        self.env = dict(os.environ, HOME=str(self.home),
                        CALLS_GROK=str(self.home / 'grok-calls'),
                        CALLS_AGY=str(self.home / 'agy-calls'),
                        PLUGIN_NAMES=json.dumps({p['source']: p['plugin'] for p in plugins}))
        self.env.pop('DRY_RUN', None)
        self.env.pop('FAIL_INSTALL', None)
        self.assertTrue(plugins, 'no plugins to install')

    def run_activation(self, script=None, **env):
        return subprocess.run(['bash', '-eu', '-c', script or self.script],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def calls(self, cli='agy'):
        path = self.home / f'{cli}-calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def clear_calls(self):
        (self.home / 'agy-calls').unlink(missing_ok=True)

    def expected(self, selected=plugins):
        return [call for p in selected for call in (
            ['plugin', 'validate', p['source']], ['plugin', 'install', p['source']],
            ['plugin', 'enable', p['plugin']])]

    def record(self, source):
        state = self.home / '.local/state/nix-config'
        return [p for p in state.rglob('*') if p.is_file() and p.read_text().strip() == source] if state.exists() else []

    def test_first_install(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), self.expected())
        for call in self.expected():
            self.assertIn('agy output: ' + ' '.join(call), result.stdout)
        for p in plugins:
            self.assertTrue(self.record(p['source']), p)
        if not agy_only:
            self.assertTrue(any(c[:3] == ['plugin', 'install', '--trust'] for c in self.calls('grok')))
            self.assertIn(['plugin', 'enable', 'compound-engineering'], self.calls('grok'))

    def test_tree_contents(self):
        for p in plugins:
            if 'pinned' not in p:
                continue
            tree, pinned = Path(p['source']), Path(p['pinned'])
            self.assertTrue((tree / 'plugin.json').is_file())
            for name in ('AGENTS.md', 'GEMINI.md'):
                self.assertFalse((tree / name).exists(), name)
            expected = {s.name for s in (pinned / 'skills').iterdir() if s.is_dir()}
            actual = {s.name for s in (tree / 'skills').iterdir() if s.is_dir()}
            self.assertTrue(expected)
            self.assertEqual(actual, expected)

    def test_unchanged(self):
        self.assertEqual(self.run_activation().returncode, 0)
        self.clear_calls()
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [['plugin', 'enable', p['plugin']] for p in plugins])
        for p in plugins:
            self.assertIn(f"Skipping unchanged Antigravity plugin {p['plugin']}", result.stdout)

    def test_changed_tree(self):
        self.assertEqual(self.run_activation().returncode, 0)
        self.assertTrue(self.record(plugins[0]['source']))
        self.clear_calls()
        p = plugins[0]
        changed = str(self.home / 'changed-tree')
        replacement = self.script.replace(p['source'], changed)
        self.assertNotEqual(replacement, self.script)
        names = {p['source']: p['plugin'] for p in plugins}
        names[changed] = p['plugin']
        result = self.run_activation(replacement, PLUGIN_NAMES=json.dumps(names))
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = [['plugin', 'validate', changed], ['plugin', 'install', changed],
                    ['plugin', 'enable', p['plugin']]]
        expected += [['plugin', 'enable', other['plugin']] for other in plugins[1:]]
        self.assertEqual(self.calls(), expected)
        self.assertTrue(self.record(changed))

    def test_missing_install(self):
        self.assertEqual(self.run_activation().returncode, 0)
        self.assertTrue(self.record(plugins[0]['source']))
        self.clear_calls()
        p = plugins[0]
        shutil.rmtree(self.home / '.gemini/config/plugins' / p['plugin'])
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), self.expected(plugins[:1]) + [
            ['plugin', 'enable', other['plugin']] for other in plugins[1:]])

    def test_failed_install_retries(self):
        result = self.run_activation(FAIL_INSTALL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record(plugins[0]['source']))
        self.clear_calls()
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), self.expected())
        self.assertTrue(self.record(plugins[0]['source']))

    def test_failed_upgrade_invalidates_old_record(self):
        self.assertEqual(self.run_activation().returncode, 0)
        p = plugins[0]
        self.assertTrue(self.record(p['source']))
        changed = str(self.home / 'changed-tree')
        result = self.run_activation(self.script.replace(p['source'], changed), FAIL_INSTALL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record(p['source']))
        self.assertFalse(self.record(changed))

    @unittest.skipIf(agy_only, 'dry-run guard belongs to the activation wrapper')
    def test_dry_run(self):
        result = self.run_activation(DRY_RUN='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.home / '.local/state/nix-config').exists())


if __name__ == '__main__':
    unittest.main()
