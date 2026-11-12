"""Decrypt and validate a host's wired network declaration.

macos-wired-network and nixos-wired-network import this module, so both read
the same SOPS file the same way. Nothing here prints a declared value: a
Problem's text names a key or a condition, never what the file holds.
"""
import ipaddress
import json
import os
import pwd
import re
import stat
import subprocess

MAC_PATTERN = re.compile(r'[0-9a-f]{1,2}(?::[0-9a-f]{1,2}){5}')


class Problem(Exception):
    pass


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


def decrypt(source, identity, timeout):
    env = {k: v for k, v in os.environ.items() if not k.startswith('SOPS_AGE_')}
    env['SOPS_AGE_KEY_FILE'] = str(identity)
    try:
        result = subprocess.run(['sops', '--decrypt', '--output-type', 'json', str(source)],
                                env=env, capture_output=True, check=False, timeout=timeout)
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


def guarded(say, outcome, action):
    try:
        action()
    except Problem as problem:
        say(f'{problem}; {outcome}')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # The message of an unexpected error can quote decrypted input, so only
        # its type is printed.
        say(f'unexpected {type(error).__name__}; {outcome}')
