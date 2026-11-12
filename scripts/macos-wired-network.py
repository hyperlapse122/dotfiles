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
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from wired_network_common import (Problem, check_identity, declaration, decrypt, dns_address,
                                  guarded, normalize_mac)

NAME = 'macos-wired-network'
# Long enough for a slow sops or configd, short enough that a wedged one
# never holds the switch.
TIMEOUT = 60


def say(message):
    print(f'{NAME}: {message}', file=sys.stderr)


def networksetup():
    found = shutil.which('networksetup', path=os.environ.get('PATH', '') + ':/usr/sbin')
    if not found:
        raise Problem('networksetup was not found')
    return found


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
    declared = declaration(decrypt(Path(arguments.file), identity, TIMEOUT))
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
    guarded(say, 'the wired adapter was left as it is', lambda: run(arguments))


if __name__ == '__main__':
    main()
