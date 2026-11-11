"""Bring the Mac's wired adapter to its declared network settings.

nix-darwin production activation runs this as root:

  macos-wired-network --file FILE --identity KEY --owner USER

FILE is the host's SOPS-encrypted declaration with `mac`, `ipv4_address`,
`ipv4_subnet_mask`, `ipv4_router`, and `dns_servers`. The network service
whose hardware port has that MAC gets a manual IPv4 configuration, exactly
those DNS servers in order, and IPv6 turned off. Only groups that differ are
written, each announced with one line naming the group and the service.

No port with that MAC means the adapter is unplugged: exit 0 with no output.
Every other problem prints one warning and exits 0, so the switch goes on.
No declared value is ever printed, and networksetup's own error output is
dropped because it can repeat the arguments it rejected.
"""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys

NAME = 'macos-wired-network'
# Long enough for a slow sops or configd, short enough that a wedged one
# never holds the switch.
TIMEOUT = 60
MAC_PATTERN = re.compile(r'[0-9a-f]{1,2}(?::[0-9a-f]{1,2}){5}')


class Problem(Exception):
    """A condition that leaves the adapter untouched; its text names no value."""


def say(message):
    print(f'{NAME}: {message}', file=sys.stderr)


def networksetup():
    found = shutil.which('networksetup', path=os.environ.get('PATH', '') + ':/usr/sbin')
    if not found:
        raise Problem('networksetup was not found')
    return found


def check_identity(identity, owner):
    try:
        metadata = identity.lstat()
    except FileNotFoundError:
        raise Problem(f'the age identity {identity} is missing') from None
    if not stat.S_ISREG(metadata.st_mode):
        raise Problem(f'the age identity {identity} must be a regular file')
    try:
        owner_uid = pwd.getpwnam(owner).pw_uid
    except KeyError:
        raise Problem(f'the identity owner {owner} does not exist') from None
    if metadata.st_uid != owner_uid:
        raise Problem(f'the age identity {identity} must be owned by {owner}')
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise Problem(f'the age identity {identity} must have mode 0600')


def decrypt(source, identity):
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOPS_AGE_')}
    env['SOPS_AGE_KEY_FILE'] = str(identity)
    try:
        result = subprocess.run(['sops', '--decrypt', '--output-type', 'json', str(source)],
                                env=env, capture_output=True, check=False, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Problem(f'decrypting {source} timed out') from None
    if result.returncode:
        raise Problem(f'cannot decrypt {source} with the host age identity')
    try:
        data = json.loads(result.stdout)
    except ValueError:
        raise Problem(f'{source} does not decrypt to a map') from None
    if not isinstance(data, dict):
        raise Problem(f'{source} does not decrypt to a map')
    return data


def normalize_mac(value):
    if not isinstance(value, str):
        return None
    mac = value.strip().lower().replace('-', ':')
    if not MAC_PATTERN.fullmatch(mac):
        return None
    return ':'.join(part.zfill(2) for part in mac.split(':'))


def ipv4(value):
    try:
        return str(ipaddress.IPv4Address(value))
    except (ValueError, TypeError):
        return None


def subnet_mask(value):
    address = ipv4(value)
    if address is None:
        return None
    try:
        ipaddress.IPv4Network(f'0.0.0.0/{address}')
    except ValueError:
        return None
    return address


def dns_address(value):
    try:
        return str(ipaddress.ip_address(value))
    except (ValueError, TypeError):
        return None


def declaration(data):
    declared = {
        'mac': normalize_mac(data.get('mac')),
        'ipv4_address': ipv4(data.get('ipv4_address')),
        'ipv4_subnet_mask': subnet_mask(data.get('ipv4_subnet_mask')),
        'ipv4_router': ipv4(data.get('ipv4_router')),
    }
    for key, value in declared.items():
        if value is None:
            raise Problem(f'the declaration has a missing or invalid {key}')
    servers = data.get('dns_servers')
    addresses = [dns_address(server) for server in servers] if isinstance(servers, list) else []
    if not addresses or None in addresses:
        raise Problem('the declaration has a missing or invalid dns_servers')
    declared['dns_servers'] = addresses
    return declared


def read(tool, *args):
    try:
        result = subprocess.run([tool, *args], capture_output=True, text=True, check=False,
                                timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Problem(f'networksetup {args[0]} timed out') from None
    if result.returncode:
        raise Problem(f'networksetup {args[0]} failed')
    return result.stdout


def device_for_mac(tool, mac):
    device = None
    for line in read(tool, '-listallhardwareports').splitlines():
        key, _, value = line.partition(':')
        if key.strip() == 'Hardware Port':
            device = None
        elif key.strip() == 'Device':
            device = value.strip()
        elif key.strip() == 'Ethernet Address' and normalize_mac(value) == mac and device:
            return device
    return None


def service_for_device(tool, device):
    service = None
    for line in read(tool, '-listnetworkserviceorder').splitlines():
        line = line.strip()
        named = re.fullmatch(r'\((?:\d+|\*)\)\s+(.+)', line)
        if named:
            service = named.group(1)
            continue
        port = re.fullmatch(r'\(Hardware Port: .*, Device: (\S*)\)', line)
        if port and service and port.group(1) == device:
            return service
    return None


def current_state(tool, service):
    info = {}
    lines = read(tool, '-getinfo', service).splitlines()
    for line in lines:
        key, separator, value = line.partition(':')
        if separator and key.strip() not in info:
            info[key.strip()] = value.strip()
    manual = bool(lines) and lines[0].strip() == 'Manual Configuration'
    dns_output = read(tool, '-getdnsservers', service).splitlines()
    servers = [line.strip() for line in dns_output if dns_address(line.strip())]
    return {
        'ipv4': (info.get('IP address'), info.get('Subnet mask'), info.get('Router')) if manual else None,
        'dns': servers,
        'ipv6_off': info.get('IPv6') == 'Off',
    }


def reconcile(tool, service, declared):
    state = current_state(tool, service)
    wanted_ipv4 = (declared['ipv4_address'], declared['ipv4_subnet_mask'], declared['ipv4_router'])
    writes = []
    if state['ipv4'] != wanted_ipv4:
        writes.append(('IPv4', ['-setmanual', service, *wanted_ipv4]))
    if state['dns'] != declared['dns_servers']:
        writes.append(('DNS', ['-setdnsservers', service, *declared['dns_servers']]))
    if not state['ipv6_off']:
        writes.append(('IPv6', ['-setv6off', service]))
    for group, args in writes:
        try:
            failed = subprocess.run([tool, *args], capture_output=True, check=False,
                                    timeout=TIMEOUT).returncode != 0
        except subprocess.TimeoutExpired:
            failed = True
        if failed:
            say(f'could not set {group} on {service}')
        else:
            say(f'set {group} on {service}')


def run(arguments):
    identity = Path(arguments.identity)
    check_identity(identity, arguments.owner)
    declared = declaration(decrypt(Path(arguments.file), identity))
    tool = networksetup()
    device = device_for_mac(tool, declared['mac'])
    if device is None:
        return
    service = service_for_device(tool, device)
    if service is None:
        return
    reconcile(tool, service, declared)


def main():
    parser = argparse.ArgumentParser(prog=NAME, description=__doc__.splitlines()[0])
    parser.add_argument('--file', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--owner', required=True)
    arguments = parser.parse_args()
    try:
        run(arguments)
    except Problem as problem:
        say(f'{problem}; the wired adapter was left as it is')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # The message of an unexpected error can quote decrypted input, so only
        # its type is printed.
        say(f'unexpected {type(error).__name__}; the wired adapter was left as it is')


if __name__ == '__main__':
    main()
