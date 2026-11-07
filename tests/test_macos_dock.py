import copy
import importlib.util
import json
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('macos_dock', REPO / 'scripts/macos-dock.py')
dock = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dock)


class MemoryPreferences:
    def __init__(self, values=None):
        self.values = copy.deepcopy(values or {})
        self.writes = []

    def read(self):
        return copy.deepcopy(self.values)

    def write(self, key, value):
        self.values[key] = copy.deepcopy(value)
        self.writes.append(key)


class DockTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='dock-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / 'personal home'
        self.home.mkdir()
        self.apps = self.root / 'Applications'
        self.apps.mkdir()
        self.settings = json.loads((REPO / 'home/.chezmoidata/macos-dock.json').read_text())['macosDock']
        self.prefs = MemoryPreferences({'orientation': 'left', 'magnification': True})
        self.restarts = []

    def install(self, name, root=None):
        path = (root or self.apps) / name
        path.mkdir(parents=True, exist_ok=True)
        return path

    def apply(self):
        return dock.reconcile(self.settings, self.home, self.prefs,
                              roots=[self.apps, self.home / 'Applications'],
                              restart=lambda: self.restarts.append(True))

    def paths(self, key='persistent-apps'):
        return [dock.tile_path(tile) for tile in self.prefs.values[key]]

    def test_approved_order_exclusions_and_repeat_apply(self):
        expected = ['Google Chrome', 'App Store', 'Mail', 'Calendar', 'Reminders', 'Notes',
                    'Messages', 'FaceTime', 'Phone', 'Photos', 'Music', 'iPhone Mirroring',
                    'Microsoft Outlook', 'Microsoft Teams', 'Microsoft Word', 'Microsoft Excel',
                    'Microsoft PowerPoint', 'Ghostty', 'T3 Code (Beta)', 'ChatGPT', 'Claude']
        for app in [*expected, '1Password', 'Microsoft OneNote', 'Safari']:
            self.install(app + '.app')
        self.assertTrue(self.apply())
        self.assertEqual(self.paths(), [self.apps / (name + '.app') for name in expected])
        self.assertEqual(self.paths('persistent-others'), [self.home / 'Downloads'])
        self.assertEqual(self.prefs.values['tilesize'], 32)
        self.assertIs(self.prefs.values['show-recents'], False)
        self.assertEqual(self.prefs.values['orientation'], 'left')
        self.assertIs(self.prefs.values['magnification'], True)
        writes = list(self.prefs.writes)
        self.assertFalse(self.apply())
        self.assertEqual(self.prefs.writes, writes)
        self.assertEqual(self.restarts, [True])

    def test_missing_apps_later_installed_and_manual_drift(self):
        teams = self.install('Microsoft Teams.app')
        excel = self.install('Microsoft Excel.app')
        self.apply()
        self.assertEqual(self.paths(), [teams, excel])
        word = self.install('Microsoft Word.app')
        extra = self.install('Safari.app')
        self.prefs.values['persistent-apps'] = [dock.make_tile(extra), dock.make_tile(excel)]
        self.prefs.values['tilesize'] = 100
        self.apply()
        self.assertEqual(self.paths(), [teams, word, excel])
        self.assertEqual(self.prefs.values['tilesize'], 32)

    def test_retained_tile_metadata_and_encoded_paths(self):
        app = self.install('Ghostty.app', self.home / 'Applications')
        tile = dock.make_tile(app)
        tile['tile-data']['file-label'] = '터미널'
        tile['GUID'] = 123456
        tile['tile-data']['file-data']['_CFURLString'] += '/'
        downloads = dock.make_tile(self.home / 'Downloads', folder=True)
        downloads['tile-data']['displayas'] = 1
        self.prefs.values.update({'persistent-apps': [tile], 'persistent-others': [downloads]})
        self.apply()
        self.assertEqual(self.prefs.values['persistent-apps'], [tile])
        self.assertEqual(self.prefs.values['persistent-others'], [downloads])
        self.assertEqual(self.paths(), [app])

    def test_t3_bundle_variants_do_not_duplicate_pin(self):
        stable = self.install('T3 Code.app')
        self.apply()
        self.assertEqual(self.paths(), [stable])
        beta = self.install('T3 Code (Beta).app')
        self.apply()
        self.assertEqual(self.paths(), [beta])

    def test_write_failure_is_reported_and_does_not_restart(self):
        with patch.object(self.prefs, 'write', side_effect=RuntimeError('write denied')):
            with self.assertRaisesRegex(RuntimeError, 'write denied'):
                self.apply()
        self.assertEqual(self.restarts, [])

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_hook_platform_guards_and_shell_quoting(self):
        for operating_system, arch in [('darwin', 'arm64'), ('darwin', 'amd64'),
                                       ('linux', 'arm64'), ('windows', 'amd64')]:
            with self.subTest(os=operating_system, arch=arch):
                rendered = self.render_hook(operating_system, arch)
                if (operating_system, arch) == ('darwin', 'arm64'):
                    self.assertIn('macos-dock.py', rendered)
                    if os.name != 'nt':
                        syntax = subprocess.run(['/bin/sh', '-n'], input=rendered,
                                                capture_output=True, text=True)
                        self.assertEqual(syntax.returncode, 0, syntax.stderr)
                else:
                    self.assertEqual(rendered.strip(), '')

    def render_hook(self, operating_system='darwin', arch='arm64'):
        source = self.root / 'source'
        templates = source / '.chezmoitemplates'
        templates.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / 'home/.chezmoiscripts/run_after_90-macos-dock.sh.tmpl', templates / 'dock-hook')
        config = self.root / 'empty.toml'
        config.write_text('')
        data = {'chezmoi': {'os': operating_system, 'arch': arch, 'workingTree': str(REPO),
                           'destDir': str(self.home)}, 'macosDock': self.settings}
        template = '{{ $data := ' + json.dumps(json.dumps(data)) + ' | fromJson }}{{ includeTemplate "dock-hook" $data }}'
        result = subprocess.run([shutil.which('chezmoi'), '--source', str(source), '--config', str(config),
                                 'execute-template', template], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    @unittest.skipUnless(os.name != 'nt' and shutil.which('chezmoi'), 'POSIX chezmoi required')
    def test_real_chezmoi_reconciles_every_apply_without_live_preferences(self):
        # Run the rendered hook and production CLI with fixture storage and app roots.
        self.home = self.root / "home with ' quote"
        self.home.mkdir()
        self.install('Ghostty.app')
        rendered = self.render_hook()
        scripts = self.root / 'source/.chezmoiscripts'
        scripts.mkdir()
        (scripts / 'run_after_90-macos-dock.sh').write_text(rendered)
        commands = self.root / 'commands'
        commands.mkdir()
        launcher = commands / 'mise'
        launcher.write_text('#!' + sys.executable + '\n' + r'''import importlib.util, json, pathlib, sys
args = sys.argv[1:]
script = args.index('python') + 1
spec = importlib.util.spec_from_file_location('dock', args[script])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = pathlib.Path(__file__).resolve().parents[1]
class Preferences:
    def read(self):
        path = root / 'values.json'
        return json.loads(path.read_text()) if path.exists() else {}
    def write(self, key, value):
        values = self.read()
        values[key] = value
        (root / 'values.json').write_text(json.dumps(values))
def restart():
    with (root / 'restarts').open('a') as f: f.write('restart\n')
original = m.reconcile
m.reconcile = lambda settings, home, prefs: original(settings, home, prefs, roots=[root / 'Applications'], restart=restart)
m.Defaults = Preferences
m.sys.platform = 'darwin'
m.platform.machine = lambda: 'arm64'
m.platform.mac_ver = lambda: ('26.0', (), '')
sys.argv = args[script:]
raise SystemExit(m.main())
''')
        launcher.chmod(0o755)
        command = [shutil.which('chezmoi'), '--source', str(self.root / 'source'),
                   '--destination', str(self.home), '--config', str(self.root / 'empty.toml'),
                   '--cache', str(self.root / 'cache'), '--persistent-state', str(self.root / 'state'),
                   '--no-tty', 'apply']
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH'])
        for _ in range(2):
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / 'restarts').read_text(), 'restart\n')
        values = json.loads((self.root / 'values.json').read_text())
        values['tilesize'] = 99
        (self.root / 'values.json').write_text(json.dumps(values))
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / 'values.json').read_text())['tilesize'], 32)
        self.assertEqual((self.root / 'restarts').read_text(), 'restart\nrestart\n')

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS defaults required')
    def test_native_defaults_roundtrip_and_idempotency_in_temporary_domain(self):
        domain = str(self.root / 'isolated dock')
        self.prefs = dock.Defaults(domain)
        self.assertEqual(self.prefs.read(), {})
        self.prefs.write('orientation', 'left')
        self.prefs.write('magnification', True)
        app = self.install('Ghostty.app')
        self.assertTrue(self.apply())
        values = self.prefs.read()
        self.assertEqual(values['tilesize'], 32)
        self.assertIs(values['show-recents'], False)
        self.assertEqual(dock.tile_path(values['persistent-apps'][0]), app)
        self.assertEqual(dock.tile_path(values['persistent-others'][0]), self.home / 'Downloads')
        self.assertEqual(values['orientation'], 'left')
        self.assertIs(values['magnification'], True)
        self.assertFalse(self.apply())
        self.assertEqual(self.restarts, [True])
        self.assertTrue(Path(domain + '.plist').is_file())


if __name__ == '__main__':
    unittest.main()
