"""Install the newest Xcode across release channels and select it after verification."""

import argparse
import errno
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import urllib.request

import pwd
import stat
from contextlib import contextmanager


class XcodeError(Exception):
    pass


@contextmanager
def terminal_input():
    with open("/dev/tty", "rb", buffering=0) as terminal:
        yield terminal, {}


def read_account(source, identity, owner):
    metadata = identity.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != pwd.getpwnam(owner).pw_uid:
        raise XcodeError("The age identity must be a regular file owned by the primary user.")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise XcodeError("The age identity must have mode 0600.")
    env = {k: v for k, v in os.environ.items() if not k.startswith("SOPS_AGE_")}
    env["SOPS_AGE_KEY_FILE"] = str(identity)
    result = subprocess.run(["sops", "--decrypt", "--output-type", "json", str(source)],
                            env=env, capture_output=True, check=False)
    if result.returncode:
        raise XcodeError("Cannot decrypt the Apple account.")
    try:
        account = json.loads(result.stdout)
        if not all(isinstance(account[k], str) and account[k].strip() for k in ("username", "password")):
            raise ValueError()
        return {k: account[k] for k in ("username", "password")}
    except (ValueError, KeyError, TypeError):
        raise XcodeError("The Apple account needs username and password fields.") from None


APPLICATIONS = Path('/Applications')
CATALOG = 'https://xcodereleases.com/data.json'
CHANNELS = {'dp': 0, 'beta': 1, 'gmSeed': 2, 'rc': 3, 'gm': 4, 'release': 5}


def numeric(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise XcodeError('Xcode release metadata contains an invalid version.')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def release_key(record):
    version = record['version']
    channel = version['release']
    if not isinstance(channel, dict) or len(channel) != 1:
        raise XcodeError('Xcode release channel metadata is invalid.')
    name, sequence = next(iter(channel.items()))
    if name not in CHANNELS or not isinstance(sequence, (int, bool)) or sequence < 1:
        raise XcodeError('Xcode release channel metadata is unsupported.')
    return numeric(version['number']), CHANNELS[name], int(sequence)


def latest(catalog):
    try:
        if not isinstance(catalog, list):
            raise ValueError()
        candidates = []
        for record in catalog:
            if record.get('name') != 'Xcode' or not record.get('version', {}).get('number'):
                continue
            architectures = record.get('links', {}).get('download', {}).get('architectures')
            if architectures is not None:
                if not isinstance(architectures, list):
                    raise ValueError()
                if 'arm64' not in architectures and 'universal' not in architectures:
                    continue
            candidates.append(record)
        chosen = max(candidates, key=release_key)
        numeric(chosen.get('requires'))
        if not re.fullmatch(r'[A-Za-z0-9]+', chosen['version'].get('build', '')):
            raise ValueError()
        return chosen
    except XcodeError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError):
        raise XcodeError('Cannot resolve the newest Xcode from complete release metadata.') from None


def fetch_catalog():
    try:
        request = urllib.request.Request(CATALOG, headers={'User-Agent': 'dotfiles-xcode'})
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except Exception:
        raise XcodeError('Cannot refresh Xcode release metadata; check network and TLS trust.') from None


def run_command(argv, *, env=None, check=True):
    try:
        result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, encoding='utf-8', timeout=180)
        if check and result.returncode:
            raise XcodeError('Xcode verification command failed; the previous selection was retained.')
        return result
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise XcodeError('Cannot run the required native Xcode tool.') from None


def host_version():
    return run_command(['/usr/bin/sw_vers', '-productVersion']).stdout.strip()


class Redactor:
    def __init__(self, values):
        self.secrets = tuple(sorted((value.encode('utf-8') for value in values if value), key=len, reverse=True))
        self.pending = b''

    def feed(self, data):
        buffer = self.pending + data
        position = 0
        result = bytearray()
        while position < len(buffer):
            if any(len(secret) > len(buffer) - position and secret.startswith(buffer[position:])
                   for secret in self.secrets):
                break
            match = next((secret for secret in self.secrets if buffer.startswith(secret, position)), None)
            if match is not None:
                result.extend(b'[redacted]')
                position += len(match)
            else:
                result.append(buffer[position])
                position += 1
        self.pending = buffer[position:]
        return bytes(result)

    def finish(self):
        result = b'[redacted]' if self.pending else b''
        self.pending = b''
        return result


def run_interactive(argv, *, env=None, secrets=()):
    import codecs
    import pty
    master, slave = pty.openpty()
    child = None
    decoder = codecs.getincrementaldecoder('utf-8')('replace')
    redactor = Redactor(secrets)
    try:
        with terminal_input() as (terminal, terminal_env):
            child = subprocess.Popen(argv, stdin=terminal, stdout=slave, stderr=slave,
                                     env=terminal_env if env is None else env)
        os.close(slave)
        slave = None
        while True:
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            sys.stdout.write(decoder.decode(redactor.feed(chunk)))
            sys.stdout.flush()
        sys.stdout.write(decoder.decode(redactor.finish(), final=True))
        sys.stdout.flush()
        if child.wait():
            raise XcodeError('Xcode installation or authorization failed; the previous selection was retained.')
    except (OSError, subprocess.SubprocessError):
        raise XcodeError('Cannot run the interactive Xcode installer.') from None
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait()
        os.close(master)
        if slave is not None:
            os.close(slave)


def installed_candidate(release):
    for app in sorted(APPLICATIONS.glob('Xcode*.app')):
        try:
            with (app / 'Contents/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            with (app / 'Contents/version.plist').open('rb') as stream:
                version = plistlib.load(stream)
            if (info.get('CFBundleIdentifier') == 'com.apple.dt.Xcode'
                    and numeric(info.get('CFBundleShortVersionString')) == numeric(release['version']['number'])
                    and version.get('ProductBuildVersion') == release['version']['build']):
                return app.resolve()
        except (OSError, ValueError, plistlib.InvalidFileException, XcodeError):
            continue
    return None


def verify_candidate(app):
    run_command(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--test-requirement',
                 '=anchor apple and identifier "com.apple.dt.Xcode"', str(app)])
    run_command(['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)])
    developer = app / 'Contents/Developer'
    build = developer / 'usr/bin/xcodebuild'
    env = os.environ.copy()
    for name in ('DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS'):
        env.pop(name, None)
    env['DEVELOPER_DIR'] = str(developer)
    if run_command([str(build), '-checkFirstLaunchStatus'], env=env, check=False).returncode:
        run_interactive(['/usr/bin/sudo', str(build), '-license', 'accept'], env=env)
        run_interactive(['/usr/bin/sudo', str(build), '-runFirstLaunch'], env=env)
        run_command([str(build), '-checkFirstLaunchStatus'], env=env)
    clang = run_command(['/usr/bin/xcrun', '--find', 'clang'], env=env).stdout.strip()
    sdk = run_command(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env).stdout.strip()
    if not clang or not sdk:
        raise XcodeError('The candidate Xcode compiler or macOS SDK is unavailable.')
    run_command([clang, '--version'], env=env)


def update(source, identity, owner):
    release = latest(fetch_catalog())
    required = release['requires']
    if numeric(host_version()) < numeric(required):
        raise XcodeError('The newest Xcode requires macOS ' + required + ' or later; update macOS and rerun.')
    app = installed_candidate(release)
    if app is None:
        channel, sequence = next(iter(release['version']['release'].items()))
        if channel == 'gmSeed':
            raise XcodeError('The pinned Xcode installer cannot select GM Seed releases; update installer support before retrying.')
        label = {'beta': 'Beta', 'rc': 'Release Candidate', 'dp': 'DP'}.get(channel)
        version = release['version']['number']
        if label:
            version += ' ' + label
            if sequence > 1:
                version += ' ' + str(sequence)
        account = read_account(source, identity, owner)
        env = os.environ.copy()
        for name in ('DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS', 'XCODES_DIRECTORY'):
            env.pop(name, None)
        env.update({'XCODES_USERNAME': account['username'], 'XCODES_PASSWORD': account['password']})
        print('Installing Xcode ' + version + ' (' + release['version']['build'] + ').', flush=True)
        run_interactive(['xcodes', 'install', version, '--update', '--directory', str(APPLICATIONS), '--no-aria2', '--no-color'],
                        env=env, secrets=account.values())
        app = installed_candidate(release)
        if app is None:
            raise XcodeError('The installed Xcode does not match the selected release build.')
    verify_candidate(app)
    env = os.environ.copy()
    env.pop('DEVELOPER_DIR', None)
    current = run_command(['/usr/bin/xcode-select', '--print-path'], env=env, check=False).stdout.strip()
    developer = str(app / 'Contents/Developer')
    if current != developer:
        run_interactive(['/usr/bin/sudo', '/usr/bin/xcode-select', '--switch', developer], env=env)
    print('Xcode ' + release['version']['number'] + ' (' + release['version']['build'] + ') is ready.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--owner', required=True)
    args = parser.parse_args()
    try:
        if platform.system() != 'Darwin' or platform.machine() != 'arm64':
            raise XcodeError('Xcode provisioning requires native Apple Silicon macOS.')
        update(args.source, args.identity, args.owner)
    except XcodeError as error:
        print(str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Xcode setup cancelled; the previous selection was retained.', file=sys.stderr)
        return 1
    except Exception:
        print('Xcode setup failed; no credential details were printed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
