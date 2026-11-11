"""Exercise the packaged macos-wired-network against a stubbed networksetup.

Usage: test_macos_wired_network.py <macos-wired-network> <fake-secrets-dir>

The real sops decrypts the fake files from tests/lib/fake-secrets.nix. A
networksetup stub on PATH answers from a JSON state file, records every call,
and, when told to fail a write, prints its arguments to stderr as a real
networksetup error can.
"""
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(sys.argv[1])
SECRETS = Path(sys.argv[2])
sys.argv[1:] = []

SERVICE = 'Thunderbolt Ethernet Slot 0'
MAC = '02:00:5e:00:53:01'
SECRET_VALUES = ['192.0.2.100', '192.0.2.1', '255.255.255.0',
                 '198.51.100.20', '198.51.100.21', '02:00:5e:00:53:01',
                 '02:00:5E:00:53:01']

STUB = r'''import json, os, sys
state = json.load(open(os.environ['STATE']))
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\n')
command = args[0]
if command in state.get('fail', []):
    sys.stderr.write('** Error: ' + ' '.join(args) + '\n')
    sys.exit(1)
if command == '-listallhardwareports':
    print(state['ports'])
elif command == '-listnetworkserviceorder':
    print(state['order'])
elif command == '-getinfo':
    print(state['info'][args[1]])
elif command == '-getdnsservers':
    print(state['dns'][args[1]])
'''

PORTS = '''
Hardware Port: Thunderbolt Ethernet Slot 0
Device: en7
Ethernet Address: {mac}

Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 0a:1b:2c:3d:4e:5f

VLAN Configurations
==================='''

ORDER = '''An asterisk (*) denotes that a network service is disabled.
({mark}) {service}
(Hardware Port: Thunderbolt Ethernet Slot 0, Device: en7)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)
'''

MATCHING_INFO = '''Manual Configuration
IP address: 192.0.2.100
Subnet mask: 255.255.255.0
Router: 192.0.2.1
IPv6: Off
Ethernet Address: 02:00:5e:00:53:01'''

DHCP_INFO = '''DHCP Configuration
IP address: 169.254.10.10
Subnet mask: 255.255.0.0
Router: (null)
Client ID:
IPv6: Automatic
IPv6 IP address: none
IPv6 Router: none
Ethernet Address: 02:00:5e:00:53:01'''

WIFI_INFO = '''DHCP Configuration
IPv6: Automatic'''

MATCHING_DNS = '198.51.100.20\n198.51.100.21'
NO_DNS = "There aren't any DNS Servers set on " + SERVICE + '.'


class WiredNetwork(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        stub = bin_dir / 'networksetup'
        stub.write_text('#!' + sys.executable + '\n' + STUB)
        stub.chmod(0o755)
        self.calls = self.root / 'calls.log'
        self.state_file = self.root / 'state.json'
        self.identity = self.root / 'key.txt'
        shutil.copyfile(SECRETS / 'key.txt', self.identity)
        self.identity.chmod(0o600)
        self.owner = pwd.getpwuid(os.getuid()).pw_name
        env = {k: v for k, v in os.environ.items() if not k.startswith('SOPS_')}
        self.env = env | {'PATH': str(bin_dir) + ':' + os.environ['PATH'],
                          'STATE': str(self.state_file), 'CALLS': str(self.calls),
                          'HOME': str(self.root)}
        self.state = {
            'ports': PORTS.format(mac=MAC),
            'order': ORDER.format(mark='1', service=SERVICE),
            'info': {SERVICE: MATCHING_INFO, 'Wi-Fi': WIFI_INFO},
            'dns': {SERVICE: MATCHING_DNS, 'Wi-Fi': NO_DNS},
            'fail': [],
        }

    def run_tool(self, secret='wired-network.yaml', identity=None, args=None):
        self.state_file.write_text(json.dumps(self.state))
        self.calls.write_text('')
        if args is None:
            args = ['--file', str(SECRETS / secret),
                    '--identity', str(identity or self.identity),
                    '--owner', self.owner]
        result = subprocess.run([str(TOOL), *args], env=self.env,
                                capture_output=True, text=True)
        for value in SECRET_VALUES:
            self.assertNotIn(value, result.stdout + result.stderr,
                             'a declared value reached the output')
        return result

    def calls_made(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def writes(self):
        return [c for c in self.calls_made() if c[0].startswith('-set')]

    def assert_no_network_calls(self):
        self.assertEqual(self.calls_made(), [])

    def test_matching_state_changes_nothing_and_prints_nothing(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(), [])
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_dns_in_another_order_is_rewritten_alone(self):
        self.state['dns'][SERVICE] = '198.51.100.21\n198.51.100.20'
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(), [
            ['-setdnsservers', SERVICE, '198.51.100.20', '198.51.100.21']])
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr.splitlines(),
                         ['macos-wired-network: set DNS on ' + SERVICE])

    def test_missing_dns_is_set(self):
        self.state['dns'][SERVICE] = NO_DNS
        self.run_tool()
        self.assertEqual(self.writes(), [
            ['-setdnsservers', SERVICE, '198.51.100.20', '198.51.100.21']])

    def test_automatic_ipv6_is_turned_off_alone(self):
        self.state['info'][SERVICE] = MATCHING_INFO.replace('IPv6: Off', 'IPv6: Automatic')
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(), [['-setv6off', SERVICE]])

    def test_dhcp_service_gets_every_group(self):
        self.state['info'][SERVICE] = DHCP_INFO
        self.state['dns'][SERVICE] = NO_DNS
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.writes(), [
            ['-setmanual', SERVICE, '192.0.2.100', '255.255.255.0', '192.0.2.1'],
            ['-setdnsservers', SERVICE, '198.51.100.20', '198.51.100.21'],
            ['-setv6off', SERVICE]])

    def test_manual_ipv4_with_another_router_is_rewritten_alone(self):
        self.state['info'][SERVICE] = MATCHING_INFO.replace('Router: 192.0.2.1', 'Router: 192.0.2.254')
        self.run_tool()
        self.assertEqual(self.writes(), [
            ['-setmanual', SERVICE, '192.0.2.100', '255.255.255.0', '192.0.2.1']])

    def test_absent_adapter_is_skipped_silently(self):
        self.state['ports'] = PORTS.format(mac='02:00:5e:00:53:99')
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertEqual([c[0] for c in self.calls_made()], ['-listallhardwareports'])

    def test_port_with_no_service_is_skipped_silently(self):
        self.state['order'] = ORDER.format(mark='1', service=SERVICE).split('\n(2)')[0].replace('en7', 'en9')
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
        self.assertEqual(self.writes(), [])
        self.assertFalse(any(c[0] in ('-getinfo', '-getdnsservers') for c in self.calls_made()))

    def test_uppercase_mac_in_listing_matches(self):
        self.state['ports'] = PORTS.format(mac=MAC.upper())
        self.state['info'][SERVICE] = MATCHING_INFO.replace('IPv6: Off', 'IPv6: Automatic')
        self.run_tool()
        self.assertEqual(self.writes(), [['-setv6off', SERVICE]])

    def test_disabled_service_is_reconciled(self):
        self.state['order'] = ORDER.format(mark='*', service=SERVICE)
        self.state['info'][SERVICE] = MATCHING_INFO.replace('IPv6: Off', 'IPv6: Automatic')
        self.run_tool()
        self.assertEqual(self.writes(), [['-setv6off', SERVICE]])

    def test_other_services_are_never_queried_or_changed(self):
        self.state['info'][SERVICE] = DHCP_INFO
        self.run_tool()
        touched = {c[1] for c in self.calls_made() if len(c) > 1}
        self.assertEqual(touched, {SERVICE})

    def test_missing_identity_warns_and_touches_nothing(self):
        result = self.run_tool(identity=self.root / 'absent.txt')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertIn('macos-wired-network:', result.stderr)
        self.assert_no_network_calls()

    def test_loose_identity_mode_warns_and_touches_nothing(self):
        self.identity.chmod(0o644)
        result = self.run_tool()
        self.assertEqual(result.returncode, 0)
        self.assertIn('mode 0600', result.stderr)
        self.assert_no_network_calls()

    def test_identity_owned_by_another_user_warns_and_touches_nothing(self):
        others = [p.pw_name for p in pwd.getpwall() if p.pw_uid != os.getuid()]
        self.assertTrue(others)
        result = self.run_tool(args=['--file', str(SECRETS / 'wired-network.yaml'),
                                     '--identity', str(self.identity), '--owner', others[0]])
        self.assertEqual(result.returncode, 0)
        self.assertIn('owned by', result.stderr)
        self.assert_no_network_calls()

    def test_file_for_another_identity_warns_and_touches_nothing(self):
        result = self.run_tool(secret='wired-network-other.yaml')
        self.assertEqual(result.returncode, 0)
        self.assertIn('cannot decrypt', result.stderr)
        self.assert_no_network_calls()

    def test_missing_router_warns_naming_the_key(self):
        result = self.run_tool(secret='wired-network-no-router.yaml')
        self.assertEqual(result.returncode, 0)
        self.assertIn('ipv4_router', result.stderr)
        self.assert_no_network_calls()

    def test_empty_dns_list_warns_naming_the_key(self):
        result = self.run_tool(secret='wired-network-no-dns.yaml')
        self.assertEqual(result.returncode, 0)
        self.assertIn('dns_servers', result.stderr)
        self.assert_no_network_calls()

    def test_non_contiguous_subnet_mask_warns_naming_the_key(self):
        result = self.run_tool(secret='wired-network-bad-mask.yaml')
        self.assertEqual(result.returncode, 0)
        self.assertIn('ipv4_subnet_mask', result.stderr)
        self.assert_no_network_calls()

    def test_dns_entry_that_is_not_an_address_warns_naming_the_key(self):
        result = self.run_tool(secret='wired-network-bad-dns.yaml')
        self.assertEqual(result.returncode, 0)
        self.assertIn('dns_servers', result.stderr)
        self.assertNotIn('not-an-address', result.stderr)
        self.assert_no_network_calls()

    def test_unexpected_os_error_warns_and_exits_zero(self):
        result = self.run_tool(identity=self.identity / 'nested')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertIn('macos-wired-network:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assert_no_network_calls()

    def test_failed_ipv4_write_warns_and_other_groups_still_reconcile(self):
        self.state['info'][SERVICE] = DHCP_INFO
        self.state['dns'][SERVICE] = NO_DNS
        self.state['fail'] = ['-setmanual']
        result = self.run_tool()
        self.assertEqual(result.returncode, 0)
        self.assertEqual([c[0] for c in self.writes()],
                         ['-setmanual', '-setdnsservers', '-setv6off'])
        self.assertIn('macos-wired-network: could not set IPv4 on ' + SERVICE, result.stderr)

    def test_failed_listing_warns_and_writes_nothing(self):
        self.state['fail'] = ['-listallhardwareports']
        result = self.run_tool()
        self.assertEqual(result.returncode, 0)
        self.assertIn('macos-wired-network:', result.stderr)
        self.assertEqual(self.writes(), [])

    def test_missing_file_argument_is_a_usage_error(self):
        result = self.run_tool(args=['--identity', str(self.identity), '--owner', self.owner])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--file', result.stderr)


unittest.main()
