"""Enroll and privately consume the Apple account used for Xcode installation."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import auth_common as common


AccountError = common.AuthError
ITEM = '7qtqghyfcstvy4xijdgorbzvki'
GPG_ARGS = ['--no-options', '--no-auto-check-trustdb']


def parse_account(document):
    if (not isinstance(document, dict) or set(document) != {'username', 'password'}
            or any(not isinstance(value, str) or not value or '\n' in value or '\r' in value
                   or '\x00' in value for value in document.values())):
        raise AccountError('Apple account must contain one nonempty username and password.')
    return document


def parse_item(item):
    if not isinstance(item, dict) or not isinstance(item.get('fields'), list):
        raise AccountError('Cannot read the Apple login fields from 1Password.')
    values = {}
    for field in item['fields']:
        if not isinstance(field, dict):
            continue
        name = field.get('id')
        if name in ('username', 'password'):
            if name in values:
                raise AccountError('Apple login fields must be unique.')
            values[name] = field.get('value')
    return parse_account(values)


def template(source, expression, config=None):
    source = common.repository_root(source)
    config = config or source / '.chezmoi-bootstrap.toml'
    return common.run_private(common.chezmoi_argv(source, config) + ['execute-template', expression],
                              operation='Cannot read repository GPG bootstrap settings.')


def settings(source, config=None):
    result = json.loads(template(source, '{{ $g := includeTemplate "gpg-settings" . | fromJson }}'
                               '{{ dict "command" $g.program "recipient" .gpgRecipient | toJson }}', config))
    if (not isinstance(result, dict) or not isinstance(result.get('command'), str)
            or not os.path.isabs(result['command'])
            or not re.fullmatch(r'[0-9A-F]{40}|[0-9A-F]{64}', result.get('recipient', ''))):
        raise AccountError('Repository GPG settings are invalid.')
    if config is not None:
        common.require_encryption_policy(source, config)
    return result


def prepare_gpg(source, config=None):
    for partial in ('gpg-home-check.sh', 'gpg-import-recipient.sh'):
        script = template(source, '{{ includeTemplate "' + partial + '" . }}', config)
        common.run_private(['sh'], input=script, operation='Cannot prepare the repository GPG recipient.')


@contextmanager
def terminal_input():
    owned = None
    try:
        stream = sys.stdin
        if not stream.isatty():
            owned = open('/dev/tty', 'rb')
            stream = owned
        env = os.environ.copy()
        env['GPG_TTY'] = os.ttyname(stream.fileno())
        yield stream, env
    except (OSError, ValueError):
        raise AccountError('Run Apple-account decryption from an interactive terminal with the hardware key connected.') from None
    finally:
        if owned is not None:
            owned.close()


def decrypt(path, gpg):
    try:
        with terminal_input() as (terminal, env):
            result = subprocess.run([gpg['command'], *GPG_ARGS, '--decrypt', str(path)],
                                    stdin=terminal, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    env=env, text=True, encoding='utf-8', timeout=180)
        if result.returncode:
            raise AccountError('Cannot decrypt the Apple account; connect the hardware key and complete its PIN prompt.')
        return parse_account(json.loads(result.stdout))
    except AccountError:
        raise
    except (OSError, ValueError, subprocess.SubprocessError):
        raise AccountError('Cannot decrypt the Apple account with the configured GPG key.') from None


def publish(target, document, gpg):
    document = parse_account(document)
    encrypted = common.run_private(
        [gpg['command'], *GPG_ARGS, '--batch', '--trust-model', 'always', '--armor',
         '--recipient', gpg['recipient'], '--encrypt'], input=json.dumps(document),
        operation='Cannot encrypt the Apple account for the verified repository recipient.')
    if not encrypted.startswith('-----BEGIN PGP MESSAGE-----'):
        raise AccountError('Apple-account encryption did not produce ciphertext.')
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    staged = None
    try:
        descriptor, name = tempfile.mkstemp(prefix='.apple-account-', suffix='.asc', dir=target.parent)
        staged = Path(name)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write(encrypted)
        if decrypt(staged, gpg) != document:
            raise AccountError('Encrypted Apple-account verification failed.')
        os.replace(staged, target)
        staged = None
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def read_account(source, config=None):
    source = common.repository_root(source)
    prepare_gpg(source, config)
    return decrypt(common.source_directory(source) / '.secrets/apple-account.json.asc', settings(source, config))


def enroll(source, config=None):
    source = common.repository_root(source)
    gpg = settings(source, config)
    prepare_gpg(source, config)
    raw = common.run_private(['op', 'item', 'get', ITEM, '--format', 'json'],
                             operation='Cannot read the Apple login from 1Password; authorize its native sign-in first.')
    try:
        document = parse_item(json.loads(raw))
    except (ValueError, TypeError):
        raise AccountError('Cannot parse the Apple login returned by 1Password.') from None
    publish(common.source_directory(source) / '.secrets/apple-account.json.asc', document, gpg)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['import', 'prepare'])
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--config', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'import':
            enroll(args.source, args.config)
            print('Encrypted Apple account published and decryption verified.')
        else:
            prepare_gpg(args.source, args.config)
            print('Repository GPG recipient prepared.')
    except AccountError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('Apple-account operation failed; no credential details were printed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
