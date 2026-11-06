import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
SPEC = importlib.util.spec_from_file_location('container_auth', REPO / 'scripts/container-auth.py')


def load_auth():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


class ContainerAuthTest(unittest.TestCase):
    def setUp(self):
        self.auth = load_auth()
        scratch = tempfile.TemporaryDirectory(prefix='container-auth-fixture-')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / 'home'
        self.helper = self.root / 'helper.py'
        self.helper.write_text('''import json,os,sys
from pathlib import Path
p=Path(os.environ['FIXTURE_STORE'])
d=json.loads(p.read_text()) if p.exists() else {}
a=sys.argv[1]
s=sys.stdin.read()
if os.environ.get('FIXTURE_FAIL'):
 print('fixture-secret-must-not-leak',file=sys.stderr);sys.exit(1)
if a=='store':
 v=json.loads(s);d[v['ServerURL']]={'Username':v['Username'],'Secret':v['Secret']};p.write_text(json.dumps(d))
elif a=='get':
 if s.strip() not in d:sys.exit(1)
 value=d[s.strip()]
 if os.environ.get('FIXTURE_WRONG_READBACK'):value={**value,'Secret':'wrong-readback'}
 print(json.dumps(value))
elif a=='erase':
 d.pop(s.strip(),None);p.write_text(json.dumps(d))
''')
        self.command = [sys.executable, str(self.helper)]
        self.env = {**os.environ, 'FIXTURE_STORE': str(self.root / 'store.json'),
                    'XDG_CONFIG_HOME': str(self.home / '.config'),
                    'XDG_RUNTIME_DIR': str(self.root / 'runtime')}
        self.records = [dict(registry='docker.io', user='fixture-user', token='fixture-secret-must-not-leak'),
                        dict(registry='registry.example.invalid', user='gitlab-user', token='gitlab-fixture')]

    def write_config(self, path, document):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document))

    def test_docker_and_podman_use_verified_helpers_and_preserve_other_hosts(self):
        paths = self.auth.configuration_paths(self.home, self.env, platform='linux')
        for path in paths:
            self.write_config(path, {'auths': {'docker.io': {'auth': 'old'},
                'REGISTRY.EXAMPLE.INVALID/team': {'auth': 'old'}, 'other.invalid': {'auth': 'retain'}},
                'credHelpers': {'other.invalid': 'retain-helper'}, 'unrelated': True})
        self.auth.reconcile(self.records, paths, self.command, 'fixture', self.env)
        for path in paths:
            config = json.loads(path.read_text())
            self.assertEqual(config['credHelpers']['registry.example.invalid'], 'fixture')
            self.assertEqual(config['credHelpers']['docker.io'], 'fixture')
            self.assertNotIn('docker.io', config['auths'])
            self.assertNotIn('REGISTRY.EXAMPLE.INVALID/team', config['auths'])
            self.assertEqual(config['auths']['other.invalid'], {'auth': 'retain'})
            self.assertTrue(config['unrelated'])
            self.assertNotIn('fixture-secret-must-not-leak', path.read_text())
        for server in self.auth.registry_aliases('docker.io'):
            self.assertEqual(self.auth.helper_get(self.command, server, self.env)['Secret'], self.records[0]['token'])
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in paths}
        self.auth.reconcile(self.records, paths, self.command, 'fixture', self.env)
        self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in paths})

    def test_store_failure_preserves_all_client_config_and_hides_child_diagnostics(self):
        path = self.home / '.docker/config.json'
        self.write_config(path, {'auths': {'docker.io': {'auth': 'old'}}})
        before = path.read_bytes()
        with self.assertRaises(self.auth.common.AuthError) as raised:
            self.auth.reconcile(self.records, [path], self.command, 'fixture', {**self.env, 'FIXTURE_FAIL': '1'})
        self.assertNotIn('fixture-secret-must-not-leak', str(raised.exception))
        self.assertEqual(path.read_bytes(), before)

    def test_malformed_second_config_is_rejected_before_native_store_changes(self):
        first, second = self.root / 'first.json', self.root / 'second.json'
        self.write_config(first, {'auths': {'docker.io': {'auth': 'old'}}})
        second.write_text('not json')
        with self.assertRaises(self.auth.common.AuthError):
            self.auth.reconcile(self.records, [first, second], self.command, 'fixture', self.env)
        self.assertFalse(Path(self.env['FIXTURE_STORE']).exists())
        self.assertIn('old', first.read_text())

    def test_invalid_helper_values_fail_before_native_or_config_changes(self):
        path = self.root / 'config.json'
        self.write_config(path, {'credHelpers': {'other.invalid': False}})
        before = path.read_bytes()
        with self.assertRaises(self.auth.common.AuthError):
            self.auth.reconcile(self.records, [path], self.command, 'fixture', self.env)
        self.assertFalse(Path(self.env['FIXTURE_STORE']).exists())
        self.assertEqual(path.read_bytes(), before)

    def test_explicit_client_paths_and_linux_runtime_precedence_are_all_reconciled(self):
        env = {**self.env, 'DOCKER_CONFIG': str(self.root / 'docker override'),
               'REGISTRY_AUTH_FILE': str(self.root / 'podman override.json')}
        paths = self.auth.configuration_paths(self.home, env, platform='linux')
        self.assertIn(self.root / 'docker override/config.json', paths)
        self.assertIn(self.root / 'podman override.json', paths)
        self.assertIn(Path(env['XDG_RUNTIME_DIR']) / 'containers/auth.json', paths)
        self.assertIn(self.home / '.config/containers/auth.json', paths)
        self.assertIn(self.home / '.docker/config.json', paths)

    def test_optional_unenrolled_apply_does_not_decrypt_or_write(self):
        source = self.root / 'source'
        (source / 'home/.secrets').mkdir(parents=True)
        (source / '.chezmoiroot').write_text('home\n')
        self.auth.apply_auth(source, None, self.home)
        self.assertFalse(self.home.exists())

    def test_registry_and_record_validation_rejects_unsafe_or_duplicate_entries(self):
        self.assertEqual(self.auth.registry_name('https://index.docker.io/v1/'), 'docker.io')
        for bad in ('http://registry.invalid', 'registry.invalid/path', '-option', 'registry.invalid\nheader'):
            with self.subTest(bad=bad), self.assertRaises(self.auth.common.AuthError):
                self.auth.registry_name(bad)
        for records in ([*self.records, self.records[0]], [dict(registry='docker.io', user='', token='x')],
                        [dict(registry='docker.io', user='u', token='secret\nextra')]):
            with self.assertRaises(self.auth.common.AuthError):
                self.auth.validate_records(records)


    def test_wrong_native_readback_never_removes_client_plaintext(self):
        path = self.root / 'config.json'
        self.write_config(path, {'auths': {'docker.io': {'auth': 'prior'}}})
        before = path.read_bytes()
        with self.assertRaises(self.auth.common.AuthError):
            self.auth.reconcile(self.records, [path], self.command, 'fixture',
                                {**self.env, 'FIXTURE_WRONG_READBACK': '1'})
        self.assertEqual(path.read_bytes(), before)

    def test_missing_client_or_pinned_helper_fails_without_config_changes(self):
        source = self.root / 'source'
        (source / 'home/.secrets').mkdir(parents=True)
        (source / '.chezmoiroot').write_text('home\n')
        (source / 'home/.secrets/container-auth.json.asc').write_text('fixture ciphertext')
        with mock.patch.object(self.auth, 'read_inventory', return_value=self.records):
            with mock.patch.object(self.auth.shutil, 'which', return_value=None):
                with self.assertRaisesRegex(self.auth.common.AuthError, 'client'):
                    self.auth.apply_auth(source, None, self.home)
            with mock.patch.object(self.auth.shutil, 'which', return_value='client-fixture'):
                with self.assertRaisesRegex(self.auth.common.AuthError, 'pinned'):
                    self.auth.apply_auth(source, None, self.home)
        self.assertFalse(self.home.exists())

    def test_native_smoke_refuses_owner_workstation(self):
        env = {**os.environ, 'GITHUB_ACTIONS': '', 'RUNNER_ENVIRONMENT': ''}
        result = subprocess.run([sys.executable, str(REPO / 'tests/smoke_container_auth.py')],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('disposable GitHub-hosted', result.stderr + result.stdout)

    def test_official_helpers_are_pinned_for_every_supported_target(self):
        data = REPO / 'home/.chezmoidata'
        apps = json.loads((data / 'personal-apps.json').read_text())['personalApps']
        locks = json.loads((data / 'personal-app-lock.json').read_text())['personalAppLocks']
        expected = {'docker-credential-wincred': {'windows-amd64', 'windows-arm64'},
                    'docker-credential-osxkeychain': {'darwin-arm64'},
                    'docker-credential-secretservice': {'linux-amd64', 'linux-arm64'}}
        for name, targets in expected.items():
            self.assertEqual(apps[name]['repository'], 'docker/docker-credential-helpers')
            self.assertEqual(set(apps[name]['targets']), targets)
            self.assertEqual(set(locks[name]['targets']), targets)
            for pin in locks[name]['targets'].values():
                self.assertEqual(pin['kind'], 'file')
                self.assertRegex(pin['sha256'], r'^[0-9a-f]{64}$')

    def test_encrypted_enrollment_roundtrip_preserves_external_input(self):
        gpg = shutil.which('gpg')
        if not gpg:
            self.skipTest('GPG required')
        source = self.root / 'source'
        (source / 'home/.secrets').mkdir(parents=True)
        (source / '.chezmoiroot').write_text('home\n')
        gpg_home = self.root / 'isolated-gpg'
        gpg_home.mkdir(mode=0o700)
        args = ['--homedir', str(gpg_home), '--no-options', '--batch']
        def command(*extra):
            result = subprocess.run([gpg, *args, *extra], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, 'Isolated GPG fixture failed')
            return result.stdout
        gpgconf = Path(gpg).with_name('gpgconf.exe' if os.name == 'nt' else 'gpgconf')
        if gpgconf.exists():
            self.addCleanup(lambda: subprocess.run([str(gpgconf), '--homedir', str(gpg_home), '--kill', 'all'], capture_output=True, timeout=30))
        command('--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
                'Registry fixture <registry@example.invalid>', 'rsa2048', 'encr', '1d')
        recipient = next(line.split(':')[9] for line in command('--with-colons', '--list-keys').splitlines() if line.startswith('fpr:'))
        token_file = self.root / 'external-token'
        token_file.write_text('fixture-secret-must-not-leak')
        policy = {'command': gpg, 'args': args, 'recipient': recipient}
        with mock.patch.object(self.auth.common, 'require_encryption_policy', return_value=policy):
            self.auth.enroll(source, None, 'docker.io', 'fixture-user', self.auth.common.read_token(token_file))
            ciphertext = source / 'home/.secrets/container-auth.json.asc'
            self.assertTrue(ciphertext.read_bytes().startswith(b'-----BEGIN PGP MESSAGE-----'))
            self.assertNotIn(token_file.read_bytes(), ciphertext.read_bytes())
            self.assertEqual(self.auth.read_inventory(source, None), [self.records[0]])
            self.assertTrue(token_file.exists())
            previous = ciphertext.read_bytes()
            with mock.patch.object(self.auth.common, 'run_private', side_effect=self.auth.common.AuthError('fixture failure')):
                with self.assertRaises(self.auth.common.AuthError):
                    self.auth.publish_inventory(source, None, self.records)
            self.assertEqual(ciphertext.read_bytes(), previous)


if __name__ == '__main__':
    unittest.main()
