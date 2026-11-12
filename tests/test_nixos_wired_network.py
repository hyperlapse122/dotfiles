"""Exercise the packaged nixos-wired-network against a stubbed nmcli.

Usage: test_nixos_wired_network.py <nixos-wired-network> <fake-secrets-dir>

The real sops decrypts the fake files from tests/lib/fake-secrets.nix. The tool
writes into a scratch directory, and an nmcli stub on PATH records every call
and can be told to fail.
"""
import configparser
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(sys.argv[1])
SECRETS = Path(sys.argv[2])
sys.argv[1:] = []

SECRET_VALUES = ['192.0.2.100', '192.0.2.1', '255.255.255.0',
                 '198.51.100.20', '198.51.100.21', '203.0.113.1',
                 '02:00:5e:00:53:01', '02:00:5E:00:53:01',
                 '2001:db8::53', 'not-an-address']
WARNING = '<4>nixos-wired-network: '
KEYFILE = 'wired-static.nmconnection'

STUB = r'''import os, sys
keyfile = os.path.exists(os.environ['KEYFILE'])
with open(os.environ['CALLS'], 'a') as log:
    log.write(' '.join(sys.argv[1:]) + (' (keyfile present)' if keyfile else '') + '\n')
sys.exit(1 if os.environ.get('NMCLI_FAILS') else 0)
'''

EXPECTED = {
    'connection': {'id': 'wired-static', 'type': 'ethernet', 'autoconnect-priority': '10'},
    'ethernet': {'mac-address': '02:00:5E:00:53:01'},
    'ipv4': {'method': 'manual', 'address1': '192.0.2.100/24,192.0.2.1',
             'dns': '198.51.100.20;198.51.100.21;'},
    'ipv6': {'method': 'disabled'},
}

REJECTED = {
    'wired-network-no-router.yaml': 'ipv4_router',
    'wired-network-router-outside.yaml': 'ipv4_router',
    'wired-network-no-dns.yaml': 'dns_servers',
    'wired-network-bad-dns.yaml': 'dns_servers',
    'wired-network-ipv6-dns.yaml': 'dns_servers',
    'wired-network-bad-mask.yaml': 'ipv4_subnet_mask',
    'wired-network-prefix-0.yaml': 'ipv4_subnet_mask',
    'wired-network-prefix-31.yaml': 'ipv4_subnet_mask',
    'wired-network-prefix-32.yaml': 'ipv4_subnet_mask',
    'wired-network-bad-mac.yaml': 'mac',
}


class WiredNetwork(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        stub = bin_dir / 'nmcli'
        stub.write_text('#!' + sys.executable + '\n' + STUB)
        stub.chmod(0o755)
        self.calls = self.root / 'calls.log'
        self.identity = self.root / 'key.txt'
        shutil.copyfile(SECRETS / 'key.txt', self.identity)
        self.identity.chmod(0o600)
        self.owner = pwd.getpwuid(os.getuid()).pw_name
        (self.root / 'run').mkdir()
        self.run_dir = self.root / 'run' / 'NetworkManager'
        self.out = self.run_dir / 'system-connections'
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOPS_')}
        self.env = env | {'PATH': str(bin_dir) + ':' + os.environ['PATH'],
                          'CALLS': str(self.calls), 'HOME': str(self.root),
                          'KEYFILE': str(self.out / KEYFILE)}

    def run_tool(self, secret='wired-network.yaml', identity=None, owner=None, fail_nmcli=False):
        self.calls.write_text('')
        env = self.env | ({'NMCLI_FAILS': '1'} if fail_nmcli else {})
        result = subprocess.run(
            [str(TOOL), '--file', str(SECRETS / secret),
             '--identity', str(identity or self.identity),
             '--owner', owner or self.owner, '--output-dir', str(self.out)],
            env=env, capture_output=True, text=True)
        for value in SECRET_VALUES:
            self.assertNotIn(value, result.stdout + result.stderr,
                             'a declared value reached the output')
        return result

    def nmcli_calls(self):
        return self.calls.read_text().splitlines()

    def keyfile(self):
        return self.out / KEYFILE

    def assert_untouched(self, result, field=None):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 1, result.stderr)
        self.assertTrue(lines[0].startswith(WARNING), lines[0])
        if field:
            self.assertIn(field, lines[0])
        self.assertFalse(self.keyfile().exists())
        self.assertEqual(self.nmcli_calls(), [])

    def test_valid_declaration_renders_the_keyfile_and_reloads(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        parser = configparser.RawConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(self.keyfile())
        self.assertEqual({s: dict(parser[s]) for s in parser.sections()}, EXPECTED)
        self.assertEqual(stat.S_IMODE(self.keyfile().stat().st_mode), 0o600)
        self.assertEqual(self.nmcli_calls(), ['connection reload (keyfile present)'])

    def test_output_directories_are_created_with_their_modes(self):
        self.run_tool()
        self.assertEqual(stat.S_IMODE(self.run_dir.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)
        self.assertEqual([p.name for p in self.out.iterdir()], [KEYFILE])

    def test_every_rejected_declaration_writes_nothing_and_names_its_field(self):
        for secret, field in REJECTED.items():
            with self.subTest(secret=secret):
                shutil.rmtree(self.run_dir, ignore_errors=True)
                self.assert_untouched(self.run_tool(secret=secret), field)

    def test_file_for_another_identity_writes_nothing(self):
        self.assert_untouched(self.run_tool(secret='wired-network-other.yaml'), 'decrypt')

    def test_loose_identity_mode_writes_nothing(self):
        self.identity.chmod(0o644)
        self.assert_untouched(self.run_tool(), '0600')

    def test_identity_owned_by_another_user_writes_nothing(self):
        others = [p.pw_name for p in pwd.getpwall() if p.pw_uid != os.getuid()]
        self.assertTrue(others)
        self.assert_untouched(self.run_tool(owner=others[0]), 'owned by')

    def test_rejected_declaration_keeps_the_earlier_keyfile(self):
        self.run_tool()
        before = self.keyfile().read_bytes()
        self.calls.write_text('')
        result = self.run_tool(secret='wired-network-router-outside.yaml')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertEqual(self.keyfile().read_bytes(), before)
        self.assertEqual(self.nmcli_calls(), [])

    def test_valid_declaration_replaces_an_earlier_keyfile(self):
        self.out.mkdir(parents=True)
        self.keyfile().write_text('[connection]\nid=stale\n')
        self.run_tool()
        self.assertIn('address1=192.0.2.100/24,192.0.2.1', self.keyfile().read_text())
        self.assertNotIn('stale', self.keyfile().read_text())
        self.assertEqual([p.name for p in self.out.iterdir()], [KEYFILE])

    def test_failing_nmcli_keeps_the_keyfile_and_stays_quiet(self):
        result = self.run_tool(fail_nmcli=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertTrue(self.keyfile().exists())

    def test_failed_write_leaves_no_temporary_file(self):
        self.out.mkdir(parents=True)
        self.keyfile().mkdir()
        result = self.run_tool()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        self.assertEqual([p.name for p in self.out.iterdir()], [KEYFILE])
        self.assertEqual(self.nmcli_calls(), [])

    def test_missing_identity_warns_and_writes_nothing(self):
        self.assert_untouched(self.run_tool(identity=self.root / 'absent.txt'), 'missing')

    def test_unexpected_os_error_warns_without_a_traceback(self):
        result = self.run_tool(identity=self.identity / 'nested')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(self.keyfile().exists())


unittest.main()
