"""Reconcile native Pi settings only during explicit dotfiles application."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess

import auth_common as common

spec = importlib.util.spec_from_file_location('synthetic_lock', Path(__file__).with_name('update-synthetic-model-lock.py'))
lock_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock_module)


def settings(document, home, lock):
    lock_module.validate_lock(lock)
    if not isinstance(document, dict):
        raise ValueError('Pi settings must be an object.')
    for key in ('packages', 'extensions'):
        values = document.get(key, [])
        if not isinstance(values, list) or any(
                not isinstance(value, str) and not (
                    key == 'packages' and isinstance(value, dict) and isinstance(value.get('source'), str))
                for value in values):
            raise ValueError('Pi resources must be arrays.')
    policy = str(home / '.pi/agent/dotfiles-policy.ts')
    document['extensions'] = [entry for entry in document.get('extensions', []) if entry != policy] + [policy]
    plugin = str(home / '.local/share/dotfiles/harness-plugins/compound-engineering')
    packages = []
    for entry in document.get('packages', []):
        source = entry if isinstance(entry, str) else entry.get('source')
        if isinstance(source, str):
            local = Path(source)
            if not local.is_absolute():
                local = home / '.pi/agent' / local
            if os.path.normcase(os.path.normpath(local)) == os.path.normcase(os.path.normpath(plugin)):
                continue
        packages.append(entry)
    # A plain native package declaration enables its manifest resources.
    document['packages'] = [*packages, plugin]
    identifiers = [model['id'] for model in lock['syntheticModelLocks']['models']]
    if document.get('defaultProvider') != 'synthetic' or document.get('defaultModel') not in identifiers:
        document['defaultModel'] = identifiers[0]
    document['defaultProvider'] = 'synthetic'
    document['enabledModels'] = ['synthetic/*']
    return document


def models(document, lock):
    lock_module.validate_lock(lock)
    if not isinstance(document, dict) or not isinstance(document.get('providers', {}), dict):
        raise ValueError('Pi models must contain a provider object.')
    catalog = lock['syntheticModelLocks']
    providers = document.setdefault('providers', {})
    providers['synthetic'] = {field: catalog[field] for field in ('baseUrl', 'api', 'models')}
    return document


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {}


def secure(path):
    if os.name != 'nt':
        path.chmod(0o600)
        return
    # No secret content is passed to PowerShell; only the private file path.
    script = '''$ErrorActionPreference = 'Stop'
$path = [Console]::In.ReadToEnd() | ConvertFrom-Json
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.FileSecurity]::new()
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
foreach ($identity in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
}
[IO.File]::SetAccessControl($path, $acl)
'''
    common.run_private(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                       input=json.dumps(str(path)), operation='Cannot secure Pi credentials.')


def install_credential(agent, plaintext):
    token = plaintext.removesuffix('\r\n') if plaintext.endswith('\r\n') else plaintext.removesuffix('\n').removesuffix('\r')
    if not token or '\n' in token or '\r' in token:
        raise ValueError('Invalid Synthetic credential.')
    auth_path = agent / 'auth.json'
    auth = read_json(auth_path)
    if not isinstance(auth, dict):
        raise ValueError('Pi auth must be an object.')
    auth['synthetic'] = {'type': 'api_key', 'key': token}
    # Secure a new same-directory file before its secret content is written.
    import tempfile
    descriptor, temporary = tempfile.mkstemp(dir=agent, prefix='.auth-')
    os.close(descriptor)
    staged = Path(temporary)
    try:
        secure(staged)
        staged.write_text(json.dumps(auth, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        os.replace(staged, auth_path)
    finally:
        staged.unlink(missing_ok=True)


def apply(source, destination, config=None):
    source = common.repository_root(source)
    home = Path(destination)
    agent = home / '.pi/agent'
    lock = json.loads((common.source_directory(source) / '.chezmoidata/synthetic-model-lock.json').read_text())
    lock_module.validate_lock(lock)
    desired_settings = settings(read_json(agent / 'settings.json'), home, lock)
    desired_models = models(read_json(agent / 'models.json'), lock)
    policy = agent / 'dotfiles-policy.ts'
    if not policy.is_file():
        raise ValueError('Pi policy is missing; apply the managed files first.')
    binary = home / '.local/bin/pi-native' / ('pi.exe' if os.name == 'nt' else 'pi')
    plugin = home / '.local/share/dotfiles/harness-plugins/compound-engineering'
    if not (plugin / 'package.json').is_file():
        raise ValueError('Pinned native CE package is missing.')
    env = os.environ.copy()
    env.update(HOME=str(home), USERPROFILE=str(home))
    env.pop('PI_CODING_AGENT_DIR', None)
    # Native registration preserves packages and repairs an owned disabled entry.
    common.run_private([str(binary), 'install', str(plugin)], env=env,
                       operation='Cannot register the pinned native Pi CE package.')
    native_settings = read_json(agent / 'settings.json')
    desired_settings['packages'] = settings(native_settings, home, lock)['packages']
    common.publish_mapping(agent / 'models.json', desired_models)
    common.publish_mapping(agent / 'dotfiles-model-lock.json', lock)
    common.publish_mapping(agent / 'settings.json', desired_settings)
    ciphertext = common.source_directory(source) / '.secrets/synthetic-api-key.asc'
    if ciphertext.is_file():
        policy = common.require_encryption_policy(source, config)
        plaintext = common.run_private([policy['command'], *policy['args'], '--decrypt'],
                                       input=ciphertext.read_text(encoding='utf-8'),
                                       operation='Cannot decrypt the Synthetic credential.')
        install_credential(agent, plaintext)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--config')
    args = parser.parse_args()
    try:
        apply(args.source, args.destination, args.config)
    except (common.AuthError, OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('Pi settings application failed; private diagnostics withheld.') from None
