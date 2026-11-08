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

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import apple_account as account


class AppleAccountTest(unittest.TestCase):
    def test_login_fields_require_one_usable_value_each(self):
        item = {'fields': [{'id': 'username', 'value': 'owner@example.invalid'},
                           {'id': 'password', 'value': 'fixture-password'}]}
        self.assertEqual(account.parse_item(item), {'username': 'owner@example.invalid', 'password': 'fixture-password'})
        for fields in [[], item['fields'] * 2, [{'id': 'username', 'value': 'a\nb'}, item['fields'][1]]]:
            with self.subTest(fields=fields), self.assertRaises(account.AccountError):
                account.parse_item({'fields': fields})

    @unittest.skipIf(os.name == 'nt', 'POSIX terminal transport')
    def test_decrypt_inherits_tty_and_captures_plaintext(self):
        import pty
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = root / 'gpg'
            marker = root / 'terminal.json'
            command.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                               'from pathlib import Path\n'
                               'marker=Path(os.environ["TTY_MARKER"])\n'
                               'if "--list-secret-keys" in sys.argv: sys.exit(2)\n'
                               'if "--card-status" in sys.argv: marker.write_text("learned"); sys.exit()\n'
                               'if not marker.exists(): sys.exit(23)\n'
                               'marker.write_text(json.dumps([sys.stdin.isatty(), os.environ.get("GPG_TTY")]))\n'
                               'print(json.dumps({"username":"fixture-user","password":"fixture-password"}))\n')
            command.chmod(0o755)
            cipher = root / 'account.asc'
            cipher.write_text('fixture ciphertext')
            master, slave = pty.openpty()
            try:
                with os.fdopen(os.dup(slave)) as terminal, mock.patch.object(sys, 'stdin', terminal), mock.patch.dict(os.environ, {'TTY_MARKER': str(marker)}):
                    result = account.decrypt(cipher, {'command': str(command), 'recipient': 'A' * 40})
                self.assertEqual(result['password'], 'fixture-password')
                self.assertEqual(json.loads(marker.read_text()), [True, os.ttyname(slave)])
            finally:
                os.close(master)
                os.close(slave)

    @unittest.skipUnless(os.name != 'nt' and shutil.which('gpg'), 'POSIX GPG required')
    def test_ciphertext_publication_round_trips_and_preserves_previous_on_failure(self):
        import pty
        with tempfile.TemporaryDirectory(prefix='apple-gpg-', dir='/tmp') as directory:
            root = Path(directory)
            keyring = root / 'gpg'
            keyring.mkdir(mode=0o700)
            env = os.environ | {'GNUPGHOME': str(keyring)}
            gpg = shutil.which('gpg')
            subprocess.run([gpg, '--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
                            '--quick-generate-key', 'Fixture <fixture@example.invalid>', 'rsa2048', 'encr', '0'],
                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            listed = subprocess.check_output([gpg, '--with-colons', '--list-keys'], env=env, stderr=subprocess.DEVNULL, text=True)
            fingerprint = next(line.split(':')[9] for line in listed.splitlines() if line.startswith('fpr:'))
            settings = {'command': gpg, 'recipient': fingerprint}
            target = root / 'account.asc'
            intended = {'username': 'fixture-user', 'password': 'fixture-password'}
            master, slave = pty.openpty()
            try:
                with os.fdopen(os.dup(slave)) as terminal, mock.patch.object(sys, 'stdin', terminal), mock.patch.dict(os.environ, env):
                    account.publish(target, intended, settings)
                    ciphertext = target.read_bytes()
                    self.assertNotIn(b'fixture-password', ciphertext)
                    self.assertEqual(account.decrypt(target, settings), intended)
                    with mock.patch.object(account, 'decrypt', side_effect=account.AccountError('fixture verification failure')):
                        with self.assertRaises(account.AccountError):
                            account.publish(target, intended | {'password': 'replacement-secret'}, settings)
                    self.assertEqual(target.read_bytes(), ciphertext)
            finally:
                os.close(master)
                os.close(slave)
                subprocess.run([shutil.which('gpgconf'), '--kill', 'all'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main()
