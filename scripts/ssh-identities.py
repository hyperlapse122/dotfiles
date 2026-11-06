#!/usr/bin/env python3
"""Enroll protected SSH identities and reconcile opt-in host routing."""

import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile

import auth_common as common

INVENTORY = '.secrets/ssh-identities.json.asc'
REPLACE_MARKER = '.secrets/ssh-replace-default'
START = '# dotfiles SSH identities:start'
END = '# dotfiles SSH identities:end'
IDENTIFIER = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}')


def _string(data, offset):
    if offset + 4 > len(data):
        raise ValueError()
    length = struct.unpack_from('>I', data, offset)[0]
    offset += 4
    if offset + length > len(data):
        raise ValueError()
    return data[offset:offset + length], offset + length


def public_key(text):
    try:
        fields = text.strip().split()
        if len(fields) < 2 or '\n' in text.strip() or '\r' in text.strip():
            raise ValueError()
        blob = base64.b64decode(fields[1], validate=True)
        kind, _ = _string(blob, 0)
        if kind.decode('ascii') != fields[0] or not fields[0].startswith(('ssh-', 'ecdsa-')):
            raise ValueError()
        return fields[0] + ' ' + base64.b64encode(blob).decode('ascii')
    except (ValueError, UnicodeError, binascii.Error, TypeError, AttributeError):
        raise common.AuthError('Invalid SSH public key.') from None


def protected_public_key(text):
    """Read the public envelope without unlocking or exporting private material."""
    try:
        lines = text.strip().splitlines()
        if lines[0] != '-----BEGIN OPENSSH PRIVATE KEY-----' or lines[-1] != '-----END OPENSSH PRIVATE KEY-----':
            raise ValueError()
        data = base64.b64decode(''.join(lines[1:-1]), validate=True)
        magic = b'openssh-key-v1\0'
        if not data.startswith(magic):
            raise ValueError()
        cipher, offset = _string(data, len(magic))
        kdf, offset = _string(data, offset)
        options, offset = _string(data, offset)
        if cipher in (b'', b'none') or kdf != b'bcrypt' or not options:
            raise ValueError()
        salt, option_offset = _string(options, 0)
        if not salt or len(options) != option_offset + 4 or struct.unpack_from('>I', options, option_offset)[0] == 0:
            raise ValueError()
        if struct.unpack_from('>I', data, offset)[0] != 1:
            raise ValueError()
        blob, offset = _string(data, offset + 4)
        encrypted, offset = _string(data, offset)
        if not encrypted or offset != len(data):
            raise ValueError()
        kind, _ = _string(blob, 0)
        return public_key(kind.decode('ascii') + ' ' + base64.b64encode(blob).decode('ascii'))
    except (ValueError, IndexError, struct.error, UnicodeError, binascii.Error, TypeError, AttributeError):
        raise common.AuthError('A passphrase-protected OpenSSH private key is required.') from None


def validate_identity(record):
    if not isinstance(record, dict) or not IDENTIFIER.fullmatch(record.get('id', '')):
        raise common.AuthError('SSH identity needs a stable simple identifier.')
    if record.get('kind') not in ('local', '1password'):
        raise common.AuthError('SSH identity source must be local or 1password.')
    hosts = record.get('hosts')
    if not isinstance(hosts, list) or not hosts or any(not isinstance(h, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', h) for h in hosts):
        raise common.AuthError('SSH identity needs explicit simple host aliases.')
    if len(set(hosts)) != len(hosts):
        raise common.AuthError('SSH host aliases must be unique.')
    for field, pattern in (('hostname', r'[A-Za-z0-9][A-Za-z0-9_.:\[\]-]*'), ('user', r'[A-Za-z0-9_][A-Za-z0-9_.@-]*')):
        if field in record and (not isinstance(record[field], str) or not re.fullmatch(pattern, record[field])):
            raise common.AuthError('Invalid SSH host routing field.')
    if 'agent_socket' in record and (not isinstance(record['agent_socket'], str) or any(c in record['agent_socket'] for c in '\r\n\0')):
        raise common.AuthError('Invalid SSH agent socket.')
    if not isinstance(record.get('replace_default', False), bool):
        raise common.AuthError('Default identity replacement must be explicit.')
    public = public_key(record.get('public_key'))
    if record['kind'] == 'local':
        if protected_public_key(record.get('private_key')) != public:
            raise common.AuthError('Protected private-key envelope does not match the public identity.')
    elif 'private_key' in record or record.get('replace_default'):
        raise common.AuthError('1Password enrollment accepts only a public identity.')
    return record


def validate_document(document):
    if not isinstance(document, dict) or not isinstance(document.get('identities'), list):
        raise common.AuthError('SSH enrollment must contain an identity list.')
    names, hosts, defaults = set(), set(), 0
    for record in document['identities']:
        validate_identity(record)
        if record['id'] in names or hosts.intersection(record['hosts']):
            raise common.AuthError('SSH identities and host aliases must be unique.')
        names.add(record['id'])
        hosts.update(record['hosts'])
        defaults += bool(record.get('replace_default'))
    if defaults > 1:
        raise common.AuthError('Only one protected identity may replace the default key.')
    return document


def read_inventory(source, config):
    target = common.source_directory(source) / INVENTORY
    if not target.exists():
        return {'identities': []}
    policy = common.require_encryption_policy(source, config)
    try:
        plaintext = common.run_private([policy['command'], *policy['args'], '--decrypt'],
                                       input=target.read_text(encoding='utf-8'), operation='Cannot decrypt SSH enrollment.')
        return validate_document(json.loads(plaintext))
    except (OSError, ValueError, UnicodeError):
        raise common.AuthError('Cannot read SSH enrollment.') from None


def publish_inventory(source, config, document):
    validate_document(document)
    policy = common.require_encryption_policy(source, config)
    text = json.dumps(document, ensure_ascii=False, allow_nan=False)
    encrypted = common.run_private([policy['command'], *policy['args'], '--armor', '--recipient', policy['recipient'], '--encrypt'],
                                   input=text, operation='SSH enrollment encryption failed.')
    if not encrypted.startswith('-----BEGIN PGP MESSAGE-----'):
        raise common.AuthError('SSH enrollment encryption failed.')
    verified = common.run_private([policy['command'], *policy['args'], '--decrypt'], input=encrypted,
                                  operation='SSH enrollment verification failed.')
    try:
        if json.loads(verified) != document:
            raise ValueError()
    except (ValueError, TypeError):
        raise common.AuthError('SSH enrollment verification failed.') from None
    directory = common.source_directory(source)
    marker = directory / REPLACE_MARKER
    replacement = any(r.get('replace_default') for r in document['identities'])
    target = directory / INVENTORY
    previous = {path: path.read_text(encoding='utf-8') if path.exists() else None
                for path in (target, marker)}
    try:
        common.publish_text(target, encrypted)
        if read_inventory(source, config) != document:
            raise common.AuthError('Published SSH enrollment verification failed.')
        if replacement:
            common.publish_text(marker, 'Protected default SSH identity enrolled.\n')
        else:
            marker.unlink(missing_ok=True)
    except Exception:
        for path, content in previous.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                common.publish_text(path, content)
        raise common.AuthError('SSH enrollment publication failed; prior enrollment retained.') from None


def enroll(source, config, record):
    validate_identity(record)
    document = read_inventory(source, config)
    document['identities'] = [r for r in document['identities'] if r['id'] != record['id']] + [record]
    document['identities'].sort(key=lambda r: r['id'])
    publish_inventory(source, config, document)


def _quote(value):
    return '"' + str(value).replace('\\', '/').replace('"', '\\"') + '"'


def _managed_config(original):
    if original.count(START) != original.count(END) or original.count(START) > 1:
        raise common.AuthError('Malformed owned SSH Include block; existing config was preserved.')
    if START in original:
        a, b = original.index(START), original.index(END) + len(END)
        if b < a:
            raise common.AuthError('Malformed owned SSH Include block; existing config was preserved.')
        original = original[:a] + original[b:].lstrip('\r\n')
    return original


def _secure(path):
    if os.name != 'nt':
        path.chmod(0o700 if path.is_dir() else 0o600)
        return
    # New descriptors exclude inherited OWNER RIGHTS entries, which Windows
    # OpenSSH rejects even when the file belongs to the current user.
    script = """$ErrorActionPreference = 'Stop'
$path = [Console]::In.ReadToEnd() | ConvertFrom-Json
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
if ([IO.Directory]::Exists($path)) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
} else {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $inherit = [Security.AccessControl.InheritanceFlags]::None
}
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @($sid, $system)) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', $inherit, 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
if ([IO.Directory]::Exists($path)) { [IO.Directory]::SetAccessControl($path, $acl) }
else { [IO.File]::SetAccessControl($path, $acl) }
"""
    common.run_private(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                       input=json.dumps(str(path)), operation='Cannot secure managed SSH files.')


def preflight_identities(document, ssh_directory, route, original):
    if not document['identities']:
        return
    executable = shutil.which('ssh')
    if not executable:
        raise common.AuthError('OpenSSH is required to verify enrolled identity selection.')
    def normalized(value):
        return os.path.normcase(os.path.normpath(value))
    with tempfile.TemporaryDirectory(prefix='dotfiles-ssh-preflight-') as temporary:
        candidate = Path(temporary) / 'config'
        candidate.write_text(route + original, encoding='utf-8')
        for record in document['identities']:
            key = ssh_directory / 'dotfiles/keys' / record['id']
            if record['kind'] == '1password':
                key = Path(str(key) + '.pub')
            for alias in record['hosts']:
                output = common.run_private([executable, '-G', '-F', str(candidate), alias],
                                            operation='Cannot verify composed SSH identity selection.')
                for line in output.splitlines():
                    option, _, value = line.partition(' ')
                    if option not in ('identityfile', 'certificatefile') or value.lower() == 'none':
                        continue
                    if option == 'certificatefile' or normalized(value) != normalized(str(key)):
                        raise common.AuthError('Conflicting SSH identities for enrolled alias ' + alias
                            + '. Exclude this alias from the preserved identity or certificate rules.')


def install_document(document, destination, *, platform):
    validate_document(document)
    ssh = Path(destination) / '.ssh'
    config = ssh / 'config'
    try:
        original = config.read_text(encoding='utf-8') if config.exists() else ''
    except (OSError, UnicodeError):
        raise common.AuthError('Cannot read existing SSH config.') from None
    original = _managed_config(original)
    include = START + '\nInclude ' + _quote(ssh / 'dotfiles/config') + '\nHost *\n' + END + '\n'
    desired = include + original
    route = '# Managed explicit SSH identities.\n'
    writes = {}
    for record in document['identities']:
        key = ssh / 'dotfiles/keys' / record['id']
        public = record['public_key'].strip() + '\n'
        public_path = Path(str(key) + '.pub')
        writes[public_path] = public
        route += 'Host ' + ' '.join(record['hosts']) + '\n'
        route += '    IdentitiesOnly yes\n    PreferredAuthentications publickey\n'
        if record.get('hostname'):
            route += '    HostName ' + record['hostname'] + '\n'
        if record.get('user'):
            route += '    User ' + record['user'] + '\n'
        if record['kind'] == 'local':
            writes[key] = record['private_key']
            route += '    IdentityFile ' + _quote(key) + '\n    IdentityAgent none\n'
            if record.get('replace_default'):
                writes[ssh / 'id_ed25519'] = record['private_key']
                writes[ssh / 'id_ed25519.pub'] = public
        else:
            route += '    IdentityFile ' + _quote(public_path) + '\n'
            if platform != 'windows':
                socket = record.get('agent_socket') or ('~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock' if platform == 'darwin' else '~/.1password/agent.sock')
                route += '    IdentityAgent ' + _quote(socket) + '\n'
    route += 'Host *\n'
    preflight_identities(document, ssh, route, original)
    writes[ssh / 'dotfiles/config'] = route
    writes[config] = desired
    for directory in (ssh, ssh / 'dotfiles', ssh / 'dotfiles/keys'):
        if directory.is_symlink():
            raise common.AuthError('Managed SSH directory must not be a symbolic link.')
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        _secure(directory)
    for path, text in writes.items():
        common.publish_text(path, text)
        _secure(path)


def apply(source, config, destination):
    source = common.repository_root(source)
    if not (common.source_directory(source) / INVENTORY).exists():
        return
    document = read_inventory(source, config)
    marker = (common.source_directory(source) / REPLACE_MARKER).exists()
    if marker != any(r.get('replace_default') for r in document['identities']):
        raise common.AuthError('SSH enrollment marker does not match its encrypted inventory.')
    platform = 'windows' if os.name == 'nt' else ('darwin' if sys.platform == 'darwin' else 'linux')
    install_document(document, destination, platform=platform)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for action in ('enroll-local', 'enroll-1password', 'apply'):
        command = commands.add_parser(action)
        command.add_argument('--source', type=Path)
        command.add_argument('--config', type=Path)
        if action == 'apply':
            command.add_argument('--destination', type=Path, required=True)
        else:
            command.add_argument('--id', required=True)
            command.add_argument('--host', action='append', required=True)
            command.add_argument('--hostname')
            command.add_argument('--user')
            command.add_argument('--public-key', type=Path, required=True)
            if action == 'enroll-local':
                command.add_argument('--private-key', type=Path, required=True)
                command.add_argument('--replace-default', action='store_true', help='Explicitly replace the legacy default identity on subsequent apply')
            else:
                command.add_argument('--agent-socket')
    args = parser.parse_args(argv)
    try:
        source = common.repository_root(args.source)
        if args.command == 'apply':
            apply(source, args.config, args.destination)
        else:
            record = {'id': args.id, 'hosts': args.host, 'kind': 'local' if args.command == 'enroll-local' else '1password',
                      'public_key': args.public_key.read_text(encoding='utf-8')}
            for field in ('hostname', 'user', 'agent_socket'):
                value = getattr(args, field, None)
                if value is not None:
                    record[field] = value
            if args.command == 'enroll-local':
                record.update(private_key=args.private_key.read_text(encoding='utf-8'), replace_default=args.replace_default)
            enroll(source, args.config, record)
    except common.AuthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('SSH identity operation failed; private diagnostics withheld.', file=sys.stderr)
        return 1
    print('SSH identity configuration verified.' if args.command == 'apply' else 'Encrypted SSH identity enrollment verified; input files retained.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
