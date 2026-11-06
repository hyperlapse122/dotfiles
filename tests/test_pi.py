import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, REPO / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PiTest(unittest.TestCase):
    def test_settings_preserve_user_resources_and_repair_owned_policy(self):
        pi = load('pi_settings', 'scripts/pi-settings.py')
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            settings = {'theme': 'custom', 'packages': ['unrelated', {'source': '/old/ce'}],
                        'extensions': ['other.ts', str(home / '.pi/agent/dotfiles-policy.ts')]}
            lock = json.loads((REPO / 'home/.chezmoidata/synthetic-model-lock.json').read_text())
            actual = pi.settings(settings, home, lock)
            self.assertEqual(actual['theme'], 'custom')
            self.assertIn('unrelated', actual['packages'])
            self.assertEqual(actual['extensions'][-1], str(home / '.pi/agent/dotfiles-policy.ts'))
            self.assertEqual(actual, pi.settings(actual, home, lock))
            self.assertEqual(actual['defaultProvider'], 'synthetic')
            self.assertIn(actual['defaultModel'], [entry['id'] for entry in lock['syntheticModelLocks']['models']])

    def test_removed_default_chooses_first_locked_id_and_invalid_settings_fail(self):
        pi = load('pi_settings', 'scripts/pi-settings.py')
        lock = json.loads((REPO / 'home/.chezmoidata/synthetic-model-lock.json').read_text())
        self.assertEqual(pi.settings({'defaultModel': 'removed'}, Path('/fixture'), lock)['defaultModel'],
                         lock['syntheticModelLocks']['models'][0]['id'])
        for invalid in ([], {'extensions': 'bad'}, {'packages': {}}, {'packages': [False]},
                        {'packages': [{}]}, {'extensions': [{}]}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                pi.settings(invalid, Path('/fixture'), lock)

    def test_models_merge_preserves_foreign_data_but_replaces_owned_provider(self):
        pi = load('pi_settings', 'scripts/pi-settings.py')
        lock = json.loads((REPO / 'home/.chezmoidata/synthetic-model-lock.json').read_text())
        previous = {'providers': {'unrelated': {'models': []}, 'synthetic': {'apiKey': 'old'}}}
        actual = pi.models(copy.deepcopy(previous), lock)
        self.assertEqual(actual['providers']['unrelated'], previous['providers']['unrelated'])
        self.assertNotIn('apiKey', actual['providers']['synthetic'])
        self.assertEqual(actual['providers']['synthetic']['models'], lock['syntheticModelLocks']['models'])
        lock['syntheticModelLocks']['models'][0]['id'] = 'quoted"model;console.log("data")'
        rendered = json.dumps(pi.models({}, lock))
        self.assertEqual(json.loads(rendered)['providers']['synthetic']['models'][0]['id'],
                         lock['syntheticModelLocks']['models'][0]['id'])

    def test_native_t3_provider_merge_and_invalid_container_preservation(self):
        chezmoi = shutil.which('chezmoi')
        self.assertIsNotNone(chezmoi, 'Install chezmoi before running Pi template tests')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / 'chezmoi.toml'
            config.write_text('')
            command = [chezmoi, '--config', str(config), '--source', str(REPO / 'home'),
                       '--destination', str(root / 'user home'), 'execute-template', '--with-stdin',
                       '{{ template "t3-code-settings" . }}']
            previous = {'providerInstances': {'pi': {'config': {'customModels': ['keep']}, 'displayName': 'Keep'}}}
            result = subprocess.run(command, input=json.dumps(previous), capture_output=True,
                                    text=True, encoding='utf-8', timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            provider = json.loads(result.stdout)['providerInstances']['pi']
            self.assertEqual(provider['driver'], 'pi')
            self.assertEqual(provider['displayName'], 'Keep')
            self.assertEqual(provider['config']['customModels'], ['keep'])
            self.assertTrue(Path(provider['config']['binaryPath']).is_absolute())
            self.assertTrue(Path(provider['config']['binaryPath']).resolve().is_relative_to(
                (root / 'user home/.local/bin').resolve()))
            for invalid in (False, None, '', [], {'config': False}, {'config': None}, {'config': []}):
                with self.subTest(invalid=invalid):
                    result = subprocess.run(command, input=json.dumps({'providerInstances': {'pi': invalid}}),
                                            capture_output=True, text=True, timeout=30)
                    self.assertNotEqual(result.returncode, 0)

    def test_credential_merge_is_private_and_invalid_input_preserves_previous(self):
        pi = load('pi_settings', 'scripts/pi-settings.py')
        with tempfile.TemporaryDirectory() as temporary:
            agent = Path(temporary)
            path = agent / 'auth.json'
            path.write_text(json.dumps({'unrelated': {'type': 'api_key', 'key': 'other-fixture'}}))
            pi.install_credential(agent, 'synthetic-fixture\n')
            result = json.loads(path.read_text())
            self.assertEqual(result['unrelated']['key'], 'other-fixture')
            self.assertEqual(result['synthetic'], {'type': 'api_key', 'key': 'synthetic-fixture'})
            if os.name != 'nt':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            previous = path.read_bytes()
            for invalid in ('', 'two\nlines', 'fixture\n\n'):
                with self.assertRaises(ValueError):
                    pi.install_credential(agent, invalid)
                self.assertEqual(path.read_bytes(), previous)
            self.assertFalse(list(agent.glob('.auth-*')))

    def test_pi_release_requires_full_archive_and_official_checksums(self):
        updater = load('pi_updater', 'scripts/update-personal-app-lock.py')
        app = {'repository': 'earendil-works/pi', 'targets': {'windows-amd64': {
            'asset': 'pi-windows-x64.zip', 'kind': 'archive', 'format': 'zip', 'stripComponents': 1}}}
        url = 'https://github.com/earendil-works/pi/releases/download/v1.5.0/'
        release = {'tag_name': 'v1.5.0', 'assets': [
            {'name': 'pi-windows-x64.zip', 'digest': 'sha256:' + 'a' * 64,
             'state': 'uploaded', 'browser_download_url': url + 'pi-windows-x64.zip'},
            {'name': 'SHA256SUMS', 'state': 'uploaded', 'browser_download_url': url + 'SHA256SUMS'}]}
        resolved = updater.resolve_pi(app, release, lambda _: 'a' * 64 + '  pi-windows-x64.zip\n')
        self.assertEqual(resolved['targets']['windows-amd64']['kind'], 'archive')
        with self.assertRaises(ValueError):
            updater.resolve_pi(app, release, lambda _: 'b' * 64 + '  pi-windows-x64.zip\n')


if __name__ == '__main__':
    unittest.main()
