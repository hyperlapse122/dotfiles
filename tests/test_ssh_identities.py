import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
SPEC = importlib.util.spec_from_file_location('ssh_identities', REPO / 'scripts/ssh-identities.py')
SSH_KEYGEN = shutil.which('ssh-keygen')
SSH = shutil.which('ssh')


def load_module():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


@unittest.skipUnless(SSH_KEYGEN and SSH, 'OpenSSH required')
class SshIdentitiesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='ssh-identities-')
        cls.root = Path(cls.scratch.name)
        cls.encrypted = cls.root / 'protected'
        cls.unprotected = cls.root / 'unprotected'
        for path, passphrase in ((cls.encrypted, 'synthetic-fixture-passphrase'), (cls.unprotected, '')):
            result = subprocess.run([SSH_KEYGEN, '-q', '-t', 'ed25519', '-N', passphrase, '-f', str(path)],
                                    capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError('Synthetic SSH fixture generation failed')

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.module = load_module()
        scratch = tempfile.TemporaryDirectory(prefix='ssh-routing-')
        self.addCleanup(scratch.cleanup)
        self.destination = Path(scratch.name)

    def identity(self, name='work'):
        return {'id': name, 'hosts': ['work.invalid'], 'kind': 'local',
                'private_key': self.encrypted.read_text(),
                'public_key': self.encrypted.with_suffix('.pub').read_text(), 'replace_default': False}

    def test_encrypted_key_requires_matching_public_envelope(self):
        record = self.identity()
        public = self.module.protected_public_key(record['private_key'])
        self.assertEqual(public, self.module.public_key(record['public_key']))
        with self.assertRaises(self.module.common.AuthError):
            self.module.validate_identity({**record, 'public_key': self.unprotected.with_suffix('.pub').read_text()})
        with self.assertRaises(self.module.common.AuthError):
            self.module.validate_identity({**record, 'private_key': self.unprotected.read_text()})

    def test_invalid_or_multikey_envelopes_and_config_injection_are_rejected(self):
        for text in (None, 7, 'not a key', '-----BEGIN OPENSSH PRIVATE KEY-----\nAA==\n-----END OPENSSH PRIVATE KEY-----'):
            with self.assertRaises(self.module.common.AuthError):
                self.module.protected_public_key(text)
        for change in ({'id': '../escape'}, {'hosts': ['good\nHost *']}, {'user': 'name\nProxyCommand evil'}, {'hosts': ['duplicate', 'duplicate']},
                       {'hostname': '-option'}, {'kind': '1password', 'private_key': 'forbidden'}):
            with self.assertRaises(self.module.common.AuthError):
                self.module.validate_identity({**self.identity(), **change})

    def test_apply_preserves_unrelated_config_and_repeats_without_changes(self):
        ssh = self.destination / '.ssh'
        ssh.mkdir()
        original = '# owned by user\nHost other.invalid\n    User someone\n'
        (ssh / 'config').write_text(original)
        document = {'identities': [self.identity()]}
        self.module.install_document(document, self.destination, platform='linux')
        config = (ssh / 'config').read_text()
        self.assertIn(original, config)
        self.assertTrue(config.startswith('# dotfiles SSH identities:start\n'))
        files = {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                 for path in ssh.rglob('*') if path.is_file()}
        self.module.install_document(document, self.destination, platform='linux')
        self.assertEqual(files, {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                                for path in ssh.rglob('*') if path.is_file()})
        output = subprocess.run([SSH, '-G', '-F', str(ssh/'config'), 'work.invalid'],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertIn('identitiesonly yes', output.stdout)
        self.assertIn('identityagent none', output.stdout)
        self.assertIn('work', output.stdout)
        other = subprocess.run([SSH, '-G', '-F', str(ssh/'config'), 'other.invalid'],
                               capture_output=True, text=True, timeout=30)
        self.assertIn('user someone', other.stdout)
        self.assertNotIn('dotfiles/keys/work', other.stdout)

    def test_onepassword_uses_public_identity_and_host_specific_agent(self):
        record = {'id': 'vault', 'hosts': ['vault.invalid'], 'kind': '1password',
                  'public_key': self.encrypted.with_suffix('.pub').read_text()}
        self.module.install_document({'identities': [record]}, self.destination, platform='linux')
        route = (self.destination/'.ssh/dotfiles/config').read_text()
        self.assertIn('IdentityAgent "~/.1password/agent.sock"', route)
        self.assertIn('IdentitiesOnly yes', route)
        self.assertFalse((self.destination/'.ssh/dotfiles/keys/vault').exists())
        self.assertTrue((self.destination/'.ssh/dotfiles/keys/vault.pub').exists())
        self.module.install_document({'identities': [record]}, self.destination, platform='windows')
        route = (self.destination/'.ssh/dotfiles/config').read_text()
        self.assertNotIn('IdentityAgent', route)

    def test_default_key_is_untouched_until_explicit_replacement(self):
        ssh = self.destination/'.ssh'
        ssh.mkdir()
        legacy = ssh/'id_ed25519'
        legacy.write_text('legacy fixture, must survive')
        self.module.install_document({'identities': [self.identity()]}, self.destination, platform='linux')
        self.assertEqual(legacy.read_text(), 'legacy fixture, must survive')
        record = {**self.identity(), 'replace_default': True}
        self.module.install_document({'identities': [record]}, self.destination, platform='linux')
        self.assertEqual(legacy.read_text(), self.encrypted.read_text())
        self.assertEqual((ssh/'id_ed25519.pub').read_text(), record['public_key'])

    def test_invalid_second_identity_leaves_all_destination_bytes_unchanged(self):
        self.module.install_document({'identities': [self.identity()]}, self.destination, platform='linux')
        files = {str(p): p.read_bytes() for p in self.destination.rglob('*') if p.is_file()}
        with self.assertRaises(self.module.common.AuthError):
            self.module.install_document({'identities': [self.identity(), {**self.identity('broken'), 'hosts': ['bad\nHost *']}]}, self.destination, platform='linux')
        self.assertEqual(files, {str(p): p.read_bytes() for p in self.destination.rglob('*') if p.is_file()})

    def test_real_gpg_enrollment_roundtrip_and_failed_replacement_rollback(self):
        gpg = shutil.which('gpg')
        if not gpg:
            self.skipTest('GPG required')
        source = self.destination/'source'
        (source/'home/.secrets').mkdir(parents=True)
        (source/'.chezmoiroot').write_text('home\n')
        gpg_home = self.destination/'gpg'
        gpg_home.mkdir(mode=0o700)
        args = ['--homedir', str(gpg_home), '--no-options', '--batch']
        def command(*extra):
            result = subprocess.run([gpg, *args, *extra], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, 'Isolated GPG fixture command failed')
            return result.stdout
        gpgconf = Path(gpg).with_name('gpgconf.exe' if os.name == 'nt' else 'gpgconf')
        if gpgconf.exists():
            self.addCleanup(lambda: subprocess.run([str(gpgconf), '--homedir', str(gpg_home), '--kill', 'all'], capture_output=True, timeout=30))
        command('--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
                'SSH fixture <ssh@example.invalid>', 'rsa2048', 'encr', '1d')
        recipient = next(line.split(':')[9] for line in command('--with-colons', '--list-keys').splitlines() if line.startswith('fpr:'))
        policy = {'command': gpg, 'args': args, 'recipient': recipient}
        with mock.patch.object(self.module.common, 'require_encryption_policy', return_value=policy):
            self.module.enroll(source, None, self.identity())
            inventory = source/'home/.secrets/ssh-identities.json.asc'
            encrypted = inventory.read_bytes()
            self.assertTrue(encrypted.startswith(b'-----BEGIN PGP MESSAGE-----'))
            self.assertNotIn(b'BEGIN OPENSSH PRIVATE KEY', encrypted)
            self.assertEqual(self.module.read_inventory(source, None), {'identities': [self.identity()]})
            self.assertTrue(self.encrypted.exists(), 'Enrollment must retain external inputs')
            original_publish = self.module.common.publish_text
            def fail_marker(path, text):
                if str(path).endswith('ssh-replace-default'):
                    raise self.module.common.AuthError('Fixture publication failure')
                return original_publish(path, text)
            with mock.patch.object(self.module.common, 'publish_text', side_effect=fail_marker):
                with self.assertRaises(self.module.common.AuthError):
                    self.module.enroll(source, None, {**self.identity(), 'replace_default': True})
            self.assertEqual(inventory.read_bytes(), encrypted)
            self.assertFalse((source/'home/.secrets/ssh-replace-default').exists())
            with self.assertRaises(self.module.common.AuthError):
                self.module.enroll(source, None, {**self.identity(), 'private_key': self.unprotected.read_text()})
            self.assertEqual(inventory.read_bytes(), encrypted)

    def test_missing_optional_enrollment_does_not_decrypt_or_change_destination(self):
        source = self.destination/'source'
        (source/'home/.secrets').mkdir(parents=True)
        (source/'.chezmoiroot').write_text('home\n')
        with mock.patch.object(self.module.common, 'require_encryption_policy', side_effect=AssertionError('must not decrypt')):
            self.module.apply(source, None, self.destination/'target')
        self.assertFalse((self.destination/'target').exists())


class SshSourceMembershipTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_replacement_marker_suppresses_legacy_files_without_decryption(self):
        with tempfile.TemporaryDirectory(prefix='ssh-source-membership-') as temporary:
            root = Path(temporary)
            source = root / 'source'
            (source / 'private_dot_ssh').mkdir(parents=True)
            (source / '.secrets').mkdir()
            shutil.copy2(REPO / 'home/.chezmoiignore', source / '.chezmoiignore')
            (source / 'private_dot_ssh/private_id_ed25519').write_text('inert legacy fixture')
            (source / 'private_dot_ssh/id_ed25519.pub').write_text('inert public fixture')
            (source / '.secrets/ssh-identities.json.asc').write_text('must not decrypt during inventory')
            config = root / 'chezmoi.toml'
            config.write_text('')
            command = [shutil.which('chezmoi'), '--config', str(config), '--source', str(source),
                       '--destination', str(root / 'home'), '--persistent-state', str(root / 'state'),
                       'managed', '--exclude=scripts']
            def managed():
                result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.replace('\\', '/')
            self.assertIn('.ssh/id_ed25519', managed())
            (source / '.secrets/ssh-replace-default').write_text('Protected default SSH identity enrolled.\n')
            self.assertNotIn('.ssh/id_ed25519', managed())


if __name__ == '__main__':
    unittest.main()

