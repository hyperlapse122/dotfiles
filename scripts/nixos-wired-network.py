"""Render the desktop's declared wired address into a NetworkManager keyfile.

A systemd unit runs this as root before NetworkManager starts:

  nixos-wired-network --file FILE --identity KEY --owner root --output-dir DIR

FILE is the host's SOPS-encrypted declaration with `mac`, `ipv4_address`,
`ipv4_subnet_mask`, `ipv4_router`, and `dns_servers`. DIR gets one keyfile,
wired-static.nmconnection, that binds a manual IPv4 profile with IPv6 off to
the adapter with that MAC. The file is written whole under a hidden name and
renamed into place. When NetworkManager is already running, `nmcli connection
reload` makes it read the file; a failure there is ignored.

Every problem prints one warning with a syslog priority prefix that names the
field but never its value, writes nothing, and exits 0. The unit must not fail
a switch, and a keyfile from an earlier run stays until the next boot, which
starts without it.
"""
import argparse
import ipaddress
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from wired_network_common import Problem, check_identity, declaration, decrypt, guarded

NAME = 'nixos-wired-network'
KEYFILE = 'wired-static.nmconnection'
# Under the unit's 30 second limit together with the nmcli call below.
SOPS_TIMEOUT = 15
NMCLI_TIMEOUT = 10


def say(message):
    print(f'<4>{NAME}: {message}', file=sys.stderr)


def validated(declared):
    if any(ipaddress.ip_address(server).version != 4 for server in declared['dns_servers']):
        raise Problem('the declaration has a missing or invalid dns_servers')
    mask = ipaddress.IPv4Network(f'0.0.0.0/{declared["ipv4_subnet_mask"]}')
    if not 1 <= mask.prefixlen <= 30:
        raise Problem('the declaration has a missing or invalid ipv4_subnet_mask')
    network = ipaddress.IPv4Network(f'{declared["ipv4_address"]}/{mask.prefixlen}', strict=False)
    if ipaddress.IPv4Address(declared['ipv4_router']) not in network:
        raise Problem('the declaration has a missing or invalid ipv4_router')
    return {**declared, 'prefix': mask.prefixlen}


def render(declared):
    return '\n'.join([
        '[connection]',
        'id=wired-static',
        'type=ethernet',
        'autoconnect-priority=10',
        '',
        '[ethernet]',
        f'mac-address={declared["mac"].upper()}',
        '',
        '[ipv4]',
        'method=manual',
        f'address1={declared["ipv4_address"]}/{declared["prefix"]},{declared["ipv4_router"]}',
        'dns=' + ''.join(f'{server};' for server in declared['dns_servers']),
        '',
        '[ipv6]',
        'method=disabled',
        '',
    ])


def write_atomically(directory, text):
    directory.parent.mkdir(mode=0o755, exist_ok=True)
    directory.mkdir(mode=0o700, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix='.wired-static-')
    try:
        with os.fdopen(descriptor, 'w') as handle:
            handle.write(text)
        os.rename(temporary, directory / KEYFILE)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def reload_networkmanager():
    nmcli = shutil.which('nmcli')
    if not nmcli:
        return
    try:
        subprocess.run([nmcli, 'connection', 'reload'], capture_output=True, check=False,
                       timeout=NMCLI_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        pass


def run(arguments):
    identity = Path(arguments.identity)
    check_identity(identity, arguments.owner)
    declared = validated(declaration(decrypt(Path(arguments.file), identity, SOPS_TIMEOUT)))
    write_atomically(Path(arguments.output_dir), render(declared))
    reload_networkmanager()


def main():
    parser = argparse.ArgumentParser(prog=NAME, description=__doc__.splitlines()[0])
    parser.add_argument('--file', required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--owner', required=True)
    parser.add_argument('--output-dir', required=True)
    arguments = parser.parse_args()
    guarded(say, 'no wired profile was written', lambda: run(arguments))


if __name__ == '__main__':
    main()
