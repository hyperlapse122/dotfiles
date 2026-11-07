#!/usr/bin/env python3
"""Enroll encrypted CA certificates and select combined trust for one child tool."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys

import auth_common as common

INVENTORY = '.secrets/ca-certificates.json.asc'
BUNDLE = '.local/share/dotfiles/ca/bundle.pem'
PUBLIC_ROOTS = '.local/share/dotfiles/ca/public-roots.pem'
CERTIFICATE = re.compile(r'-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----')
IDENTIFIER = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}')


def certificates(text):
    """Parse only complete CA PEM blocks using Python's OpenSSL CA checks."""
    if not isinstance(text, str) or 'PRIVATE KEY' in text:
        raise common.AuthError('CA input must contain only PEM CA certificates.')
    blocks = CERTIFICATE.findall(text)
    if not blocks or CERTIFICATE.sub('', text).strip():
        raise common.AuthError('CA input must contain only complete PEM CA certificates.')
    result = []
    try:
        for block in blocks:
            der = ssl.PEM_cert_to_DER_cert(block)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(der))
            if context.get_ca_certs(binary_form=True) != [der]:
                raise ValueError()
            result.append((der, ssl.DER_cert_to_PEM_cert(der)))
    except (ValueError, ssl.SSLError):
        raise common.AuthError('CA input contains an invalid or non-CA certificate.') from None
    return result


def validate_inventory(document):
    if not isinstance(document, dict) or set(document) != {'certificates'} or not isinstance(document['certificates'], dict):
        raise common.AuthError('CA inventory must contain a certificate mapping.')
    for identity, pem in document['certificates'].items():
        if not isinstance(identity, str) or not IDENTIFIER.fullmatch(identity):
            raise common.AuthError('CA inventory needs stable simple identifiers.')
        certificates(pem)
    return document


def read_inventory(source, config):
    path = common.source_directory(source) / INVENTORY
    if not path.exists():
        return {'certificates': {}}
    policy = common.require_encryption_policy(source, config)
    try:
        plaintext = common.run_private([policy['command'], *policy['args'], '--decrypt'],
            input=path.read_text(encoding='utf-8'), operation='Cannot decrypt enrolled CA certificates.')
        return validate_inventory(json.loads(plaintext))
    except (OSError, UnicodeError, ValueError):
        raise common.AuthError('Cannot read enrolled CA certificates.') from None


def publish_inventory(source, config, document):
    validate_inventory(document)
    policy = common.require_encryption_policy(source, config)
    encrypted = common.run_private([policy['command'], *policy['args'], '--armor', '--recipient', policy['recipient'], '--encrypt'],
        input=json.dumps(document, sort_keys=True), operation='CA enrollment encryption failed.')
    if not encrypted.startswith('-----BEGIN PGP MESSAGE-----'):
        raise common.AuthError('CA enrollment encryption failed.')
    verified = common.run_private([policy['command'], *policy['args'], '--decrypt'], input=encrypted,
                                  operation='CA enrollment verification failed.')
    try:
        if json.loads(verified) != document:
            raise ValueError()
    except (ValueError, TypeError):
        raise common.AuthError('CA enrollment verification failed.') from None
    target = common.source_directory(source) / INVENTORY
    previous = target.read_text(encoding='utf-8') if target.exists() else None
    try:
        common.publish_text(target, encrypted)
        if read_inventory(source, config) != document:
            raise common.AuthError('Published CA enrollment verification failed.')
    except Exception:
        if previous is None:
            target.unlink(missing_ok=True)
        else:
            common.publish_text(target, previous)
        raise common.AuthError('CA enrollment publication failed; prior enrollment retained.') from None


def enroll(source, config, identity, pem):
    document = read_inventory(source, config)
    document['certificates'][identity] = pem
    publish_inventory(source, config, document)


def remove(source, config, identity):
    document = read_inventory(source, config)
    document['certificates'].pop(identity, None)
    publish_inventory(source, config, document)


def install_bundle(document, destination, public_roots):
    validate_inventory(document)
    # Preserve the public input bytes as a prefix; parse a comment-free view only
    # for deduplication. The upstream explanatory comments remain intact.
    public_blocks = CERTIFICATE.findall(public_roots)
    public = certificates('\n'.join(public_blocks))
    seen = {der for der, _ in public}
    additions = []
    for identity in sorted(document['certificates']):
        for der, pem in certificates(document['certificates'][identity]):
            if der not in seen:
                seen.add(der)
                additions.append(pem)
    combined = public_roots
    if additions:
        combined += ('' if combined.endswith('\n') else '\n') + ''.join(additions)
    target = Path(destination) / BUNDLE
    directory = target.parent
    if directory.is_symlink():
        raise common.AuthError('Managed CA directory must not be a symbolic link.')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name != 'nt':
        directory.chmod(0o700)
    common.publish_text(target, combined)
    if os.name != 'nt':
        target.chmod(0o600)
    return target


def supported(platform):
    if platform not in ('darwin', 'linux'):
        raise common.AuthError('Managed CA-file fallback supports macOS and Linux only.')


def apply(source, config, destination, *, platform):
    source = common.repository_root(source)
    if not (common.source_directory(source) / INVENTORY).exists():
        return
    supported(platform)
    document = read_inventory(source, config)
    try:
        public = (Path(destination) / PUBLIC_ROOTS).read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        raise common.AuthError('Install the pinned public CA roots before applying enrolled certificates.') from None
    install_bundle(document, destination, public)


def execute(profile, arguments, destination, *, platform, capture_output=False):
    supported(platform)
    bundle = Path(destination) / BUNDLE
    if not bundle.is_file():
        raise common.AuthError('Apply enrolled CA certificates before selecting managed trust.')
    env = os.environ.copy()
    arguments = list(arguments)
    if arguments and arguments[0] == '--':
        arguments.pop(0)
    if profile == 'requests':
        if not arguments:
            raise common.AuthError('Requests mode requires a child command.')
        env['REQUESTS_CA_BUNDLE'] = str(bundle)
        command = arguments
    elif profile == 'curl':
        executable = shutil.which('curl')
        if not executable:
            raise common.AuthError('Install curl before selecting managed trust.')
        for name in ('CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR'):
            env.pop(name, None)
        command = [executable, '--cacert', str(bundle), *arguments]
    else:
        raise common.AuthError('Select requests or curl managed trust.')
    try:
        return subprocess.run(command, env=env, capture_output=capture_output, text=True)
    except (OSError, subprocess.SubprocessError):
        raise common.AuthError('Cannot launch the selected CA-file consumer.') from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for action in ('import', 'remove', 'apply', 'requests', 'curl'):
        command = commands.add_parser(action)
        command.add_argument('--source', type=Path)
        command.add_argument('--config', type=Path)
        if action in ('apply', 'requests', 'curl'):
            command.add_argument('--destination', type=Path, required=True)
        if action in ('import', 'remove'):
            command.add_argument('--id', required=True)
        if action == 'import':
            command.add_argument('--pem-file', type=Path, required=True)
        if action in ('requests', 'curl'):
            command.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.command in ('requests', 'curl'):
            platform = 'windows' if os.name == 'nt' else sys.platform
            return execute(args.command, args.arguments, args.destination, platform=platform).returncode
        source = common.repository_root(args.source)
        if args.command == 'import':
            enroll(source, args.config, args.id, args.pem_file.read_text(encoding='ascii'))
        elif args.command == 'remove':
            remove(source, args.config, args.id)
        else:
            apply(source, args.config, args.destination, platform='windows' if os.name == 'nt' else sys.platform)
    except common.AuthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('CA-file operation failed; private diagnostics withheld.', file=sys.stderr)
        return 1
    print('Encrypted CA enrollment verified; input retained.' if args.command in ('import', 'remove') else 'Managed CA bundle verified.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
