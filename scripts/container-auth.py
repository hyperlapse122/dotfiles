#!/usr/bin/env python3
"""Import encrypted registry credentials and configure native Docker/Podman helpers."""

import argparse
import copy
import json
import os
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import urlsplit

import auth_common as common

INVENTORY = '.secrets/container-auth.json.asc'
DOCKER_HUB = ('docker.io', 'index.docker.io', 'registry-1.docker.io',
              'https://index.docker.io/v1/', 'https://index.docker.io/v1')


def registry_name(value):
    if value in DOCKER_HUB:
        return 'docker.io'
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?', value):
        raise common.AuthError('Registry metadata requires a DNS hostname and optional port.')
    host, _, port = value.partition(':')
    if len(host) > 253 or any(not label or len(label) > 63 or label.startswith('-') or label.endswith('-')
                             for label in host.split('.')) or (port and not 0 < int(port) <= 65535):
        raise common.AuthError('Registry metadata requires a DNS hostname and optional port.')
    return value.lower()


def registry_aliases(registry):
    registry = registry_name(registry)
    return DOCKER_HUB if registry == 'docker.io' else (registry,)


def validate_records(records):
    if not isinstance(records, list):
        raise common.AuthError('Registry enrollment must contain a list.')
    seen, normalized = set(), []
    for record in records:
        if not isinstance(record, dict):
            raise common.AuthError('Registry enrollment entries must be objects.')
        registry = registry_name(record.get('registry'))
        for field in ('user', 'token'):
            value = record.get(field)
            if not isinstance(value, str) or not value or any(c in value for c in '\r\n\0'):
                raise common.AuthError('Registry enrollment needs a nonempty account and single-line token.')
        if registry in seen:
            raise common.AuthError('Registry enrollment has duplicate host aliases.')
        seen.add(registry)
        normalized.append({'registry': registry, 'user': record['user'], 'token': record['token']})
    return sorted(normalized, key=lambda record: record['registry'])


def read_inventory(source, config):
    target = common.source_directory(source) / INVENTORY
    if not target.exists():
        return []
    policy = common.require_encryption_policy(source, config)
    try:
        plaintext = common.run_private([policy['command'], *policy['args'], '--decrypt'],
            input=target.read_text(encoding='utf-8'), operation='Cannot decrypt registry enrollment.')
        return validate_records(json.loads(plaintext))
    except (OSError, ValueError, UnicodeError):
        raise common.AuthError('Cannot read registry enrollment.') from None


def publish_inventory(source, config, records):
    records = validate_records(records)
    policy = common.require_encryption_policy(source, config)
    encrypted = common.run_private([policy['command'], *policy['args'], '--armor', '--recipient',
        policy['recipient'], '--encrypt'], input=json.dumps(records, ensure_ascii=False, allow_nan=False),
        operation='Registry token encryption failed.')
    if not encrypted.startswith('-----BEGIN PGP MESSAGE-----'):
        raise common.AuthError('Registry token encryption failed.')
    plaintext = common.run_private([policy['command'], *policy['args'], '--decrypt'], input=encrypted,
                                  operation='Registry token verification failed.')
    try:
        if json.loads(plaintext) != records:
            raise ValueError()
    except (ValueError, TypeError):
        raise common.AuthError('Registry token verification failed.') from None
    target = common.source_directory(source) / INVENTORY
    previous = target.read_text(encoding='utf-8') if target.exists() else None
    try:
        common.publish_text(target, encrypted)
        if read_inventory(source, config) != records:
            raise common.AuthError('Published registry token verification failed.')
    except Exception:
        if previous is None:
            target.unlink(missing_ok=True)
        else:
            common.publish_text(target, previous)
        raise common.AuthError('Registry enrollment publication failed; prior enrollment retained.') from None


def enroll(source, config, registry, user, token):
    record = validate_records([{'registry': registry, 'user': user, 'token': token}])[0]
    records = [other for other in read_inventory(source, config) if other['registry'] != record['registry']]
    publish_inventory(source, config, [*records, record])


def configuration_paths(destination, env, *, platform):
    destination = Path(destination)
    candidates = [destination / '.docker/config.json']
    if env.get('DOCKER_CONFIG'):
        candidates.insert(0, Path(env['DOCKER_CONFIG']) / 'config.json')
    if env.get('REGISTRY_AUTH_FILE'):
        candidates.append(Path(env['REGISTRY_AUTH_FILE']))
    if platform == 'linux':
        runtime = env.get('XDG_RUNTIME_DIR')
        if runtime:
            candidates.append(Path(runtime) / 'containers/auth.json')
        elif hasattr(os, 'getuid'):
            fallback = Path('/run/user') / str(os.getuid())
            if fallback.is_dir():
                candidates.append(fallback / 'containers/auth.json')
    candidates.append(Path(env.get('XDG_CONFIG_HOME') or destination / '.config') / 'containers/auth.json')
    candidates.append(destination / '.config/containers/auth.json')
    if any(not path.is_absolute() for path in candidates):
        raise common.AuthError('Container authentication configuration paths must be absolute.')
    return list(dict.fromkeys(candidates))


def helper_get(command, server, env):
    try:
        payload = common.run_private([*command, 'get'], input=server, env=env,
                                     operation='Cannot read the native registry credential.')
        value = json.loads(payload)
        if (not isinstance(value, dict) or not isinstance(value.get('Username'), str)
                or not isinstance(value.get('Secret'), str)):
            raise ValueError()
        return {'Username': value['Username'], 'Secret': value['Secret']}
    except (common.AuthError, ValueError, TypeError):
        return None


def read_config(path):
    try:
        if path.is_symlink():
            raise common.AuthError('Container authentication config must not be a symbolic link.')
        document = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
        if not isinstance(document, dict) or any(not isinstance(document.get(key, {}), dict)
                                               for key in ('auths', 'credHelpers')):
            raise ValueError()
        if (any(not isinstance(value, str) for value in document.get('credHelpers', {}).values())
                or any(not isinstance(value, dict) for value in document.get('auths', {}).values())):
            raise ValueError()
        return document
    except (OSError, UnicodeError, ValueError):
        raise common.AuthError('Cannot read container authentication config; existing state retained.') from None


def owned_server(key, records):
    if isinstance(key, str) and key.lower().startswith(('http://', 'https://')):
        try:
            key = urlsplit(key).netloc
        except ValueError:
            return False
    return isinstance(key, str) and any(key.lower() == alias or key.lower().startswith(alias.rstrip('/') + '/')
        for record in records for alias in registry_aliases(record['registry']))


def reconcile(records, paths, command, suffix, env):
    records = validate_records(records)
    documents = [(Path(path), read_config(Path(path))) for path in paths]
    for record in records:
        expected = {'Username': record['user'], 'Secret': record['token']}
        for server in registry_aliases(record['registry']):
            if helper_get(command, server, env) != expected:
                common.run_private([*command, 'store'], input=json.dumps({'ServerURL': server, **expected}),
                    env=env, operation='Cannot store registry credentials; no plaintext fallback was used.')
            if helper_get(command, server, env) != expected:
                raise common.AuthError('Native registry credential verification failed; client config retained.')
    for path, original in documents:
        desired = copy.deepcopy(original)
        auths = desired.setdefault('auths', {})
        for key in list(auths):
            if owned_server(key, records):
                del auths[key]
        helpers = desired.setdefault('credHelpers', {})
        for record in records:
            for server in registry_aliases(record['registry']):
                helpers[server] = suffix
        if desired != original:
            common.publish_mapping(path, desired)


def helper_suffix(platform):
    return 'wincred' if platform == 'windows' else ('osxkeychain' if platform == 'darwin' else 'secretservice')


def apply_auth(source, config, destination):
    source = common.repository_root(source)
    if not (common.source_directory(source) / INVENTORY).exists():
        return False
    records = read_inventory(source, config)
    if not records:
        return False
    if not (shutil.which('docker') or shutil.which('podman')):
        raise common.AuthError('Install a Docker or Podman client before applying enrolled registry authentication.')
    platform = 'windows' if os.name == 'nt' else ('darwin' if sys.platform == 'darwin' else 'linux')
    suffix = helper_suffix(platform)
    helper = Path(destination) / '.local/bin' / ('docker-credential-' + suffix + ('.exe' if os.name == 'nt' else ''))
    if not helper.is_file():
        raise common.AuthError('Install the repository-pinned native registry credential helper before applying.')
    env = os.environ.copy()
    env['PATH'] = str(helper.parent) + os.pathsep + env.get('PATH', '')
    reconcile(records, configuration_paths(destination, env, platform=platform), [str(helper)], suffix, env)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    importer = commands.add_parser('import', help='Encrypt an opt-in registry account; preserve input')
    importer.add_argument('--registry', required=True)
    importer.add_argument('--user', required=True)
    importer.add_argument('--token-file', type=Path, required=True)
    gitlab = commands.add_parser('import-gitlab', help='Opt in the already encrypted GitLab registry account')
    applier = commands.add_parser('apply')
    applier.add_argument('--destination', type=Path, required=True)
    for child in (importer, gitlab, applier):
        child.add_argument('--source', type=Path)
        child.add_argument('--config', type=Path)
    args = parser.parse_args(argv)
    try:
        source = common.repository_root(args.source)
        if args.command == 'apply':
            if not apply_auth(source, args.config, args.destination):
                print('No registry enrollment; no changes.')
                return 0
        elif args.command == 'import':
            enroll(source, args.config, args.registry, args.user, common.read_token(args.token_file))
        else:
            record = common.read_secrets(source, args.config).get('gitlab', {})
            if not isinstance(record, dict):
                raise common.AuthError('Import a complete encrypted GitLab registry account first.')
            enroll(source, args.config, record.get('registry'), record.get('user'), record.get('token'))
    except common.AuthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('Container authentication operation failed; private diagnostics withheld.', file=sys.stderr)
        return 1
    print('Native registry authentication verified.' if args.command == 'apply'
          else 'Encrypted registry enrollment verified; external input retained.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
