import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


def updater():
    spec = importlib.util.spec_from_file_location('grok_updater', REPO / 'scripts/update-personal-app-lock.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GrokTest(unittest.TestCase):
    def render(self, template, existing=''):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'chezmoi.toml'
            config.write_text('')
            return subprocess.run([shutil.which('chezmoi'), '--config', str(config),
                                   '--source', str(REPO / 'home'), '--destination', str(Path(temporary) / "user's home"),
                                   'execute-template', '--with-stdin', '{{ template "' + template + '" . }}'],
                                  input=existing, capture_output=True, text=True, encoding='utf-8', timeout=30)

    def test_official_versioned_artifacts_are_hashed_for_every_supported_target(self):
        module = updater()
        app = json.loads((REPO / 'home/.chezmoidata/personal-apps.json').read_text())['personalApps']['grok']
        urls = []
        def digest(url):
            urls.append(url)
            return hashlib.sha256(url.encode()).hexdigest()
        result = module.resolve_grok(app, '1.0.77', digest)
        self.assertEqual(result['tag'], '1.0.77')
        self.assertEqual(urls, ['https://x.ai/cli/grok-1.0.77-' + suffix for suffix in (
            'macos-aarch64', 'linux-x86_64', 'linux-aarch64', 'windows-x86_64.exe', 'windows-aarch64.exe')])
        self.assertEqual(result['targets']['windows-amd64']['sha256'], hashlib.sha256(urls[3].encode()).hexdigest())
        for version in ('latest', '1.0.77/other', '1.0.77-beta'):
            with self.assertRaises(ValueError):
                module.resolve_grok(app, version, digest)

    def test_hashes_downloaded_bytes_and_failure_preserves_previous_complete_lock(self):
        module = updater()
        with patch.object(module, 'urlopen', return_value=io.BytesIO(b'native artifact')):
            self.assertEqual(module.download_sha256('https://x.ai/cli/fixture'),
                             hashlib.sha256(b'native artifact').hexdigest())
        with tempfile.TemporaryDirectory() as temporary:
            data = Path(temporary) / 'home/.chezmoidata'
            data.mkdir(parents=True)
            application = {'source': 'grok', 'command': 'grok', 'targets': {
                'linux-amd64': {'platform': 'linux-x86_64', 'asset': 'grok-{version}-linux-x86_64', 'kind': 'file'}}}
            (data / 'personal-apps.json').write_text(json.dumps({'personalApps': {'grok': application}}))
            lock = data / 'personal-app-lock.json'
            lock.write_text('previous complete pins')
            def unavailable(_url):
                raise OSError('fixture unavailable')
            with self.assertRaises(OSError):
                module.update_lock(Path(temporary), fetch_grok_release=lambda: '1.0.77', fetch_digest=unavailable)
            self.assertEqual(lock.read_text(), 'previous complete pins')

    def test_native_settings_preserve_unowned_tables_and_disable_compatibility(self):
        existing = '[ui]\ntheme = "custom"\n[cli]\nshow_tips = false\n[compat.claude]\nhooks = false\n'
        rendered = self.render('grok-config', existing)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        result = tomllib.loads(rendered.stdout)
        self.assertEqual(result['ui']['theme'], 'custom')
        self.assertIs(result['cli']['auto_update'], False)
        self.assertIs(result['cli']['show_tips'], False)
        self.assertIs(result['compat']['claude']['hooks'], False)
        for vendor in ('claude', 'cursor'):
            self.assertEqual({name: result['compat'][vendor][name] for name in ('agents', 'rules', 'skills')},
                             {'agents': False, 'rules': False, 'skills': False})
        again = self.render('grok-config', rendered.stdout)
        self.assertEqual(again.stdout, rendered.stdout)
        for malformed in ('cli = false', 'compat = []', '[compat]\nclaude = false', 'invalid = ['):
            with self.subTest(malformed=malformed):
                self.assertNotEqual(self.render('grok-config', malformed).returncode, 0)

    def test_t3_native_grok_provider_keeps_unrelated_configuration(self):
        previous = {'providerInstances': {'grok': {'displayName': 'Keep', 'config': {'customModels': ['keep']},
                    'environment': [{'name': 'UNRELATED', 'value': 'keep', 'sensitive': False}]}}}
        rendered = self.render('t3-code-settings', json.dumps(previous))
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        result = json.loads(rendered.stdout)['providerInstances']['grok']
        self.assertEqual(result['driver'], 'grok')
        self.assertEqual(result['displayName'], 'Keep')
        self.assertEqual(result['config']['customModels'], ['keep'])
        path = Path(result['config']['binaryPath'])
        self.assertTrue(path.is_absolute())
        self.assertEqual(path.parent.name, 'bin')
        self.assertTrue(result['enabled'] and result['config']['enabled'])
        self.assertIn({'name': 'GROK_DISABLE_AUTOUPDATER', 'value': '1', 'sensitive': False}, result['environment'])
        self.assertIn({'name': 'GROK_SUBAGENTS', 'value': '0', 'sensitive': False}, result['environment'])
        self.assertIn(previous['providerInstances']['grok']['environment'][0], result['environment'])
        self.assertNotIn('launchArgs', result['config'])
        result['environment'] += [{'name': 'GROK_SUBAGENTS', 'value': '1'}]
        again = self.render('t3-code-settings', json.dumps({'providerInstances': {'grok': result}}))
        reconciled = json.loads(again.stdout)['providerInstances']['grok']['environment']
        self.assertEqual([x['value'] for x in reconciled if x['name'] == 'GROK_SUBAGENTS'], ['0'])
        self.assertIn(previous['providerInstances']['grok']['environment'][0], reconciled)
        for invalid in (False, None, [], {'config': False}, {'environment': False}):
            with self.subTest(invalid=invalid):
                self.assertNotEqual(self.render('t3-code-settings', json.dumps({'providerInstances': {'grok': invalid}})).returncode, 0)


if __name__ == '__main__':
    unittest.main()
