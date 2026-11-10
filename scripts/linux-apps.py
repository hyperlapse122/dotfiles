"""Missing-only native Ubuntu Desktop packages, invoked by explicit application."""

from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


def inspect_host(**kwargs):
    spec = importlib.util.spec_from_file_location('linux_platform', Path(__file__).with_name('linux-platform.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.inspect_host(**kwargs)


class ProvisionError(RuntimeError):
    pass


class Installer:
    def __init__(self, *, root=Path('/'), run=subprocess.run):
        self.root = Path(root)
        self.run = run

    def command(self, args, **kwargs):
        return self.run(args, check=True, capture_output=True, **kwargs)

    def installed(self, package):
        result = self.run(['dpkg-query', '-W', '-f=${Status}', package],
                          capture_output=True, text=True, check=False)
        if result.returncode not in (0, 1):
            raise ProvisionError(f'Cannot inspect installed package {package}.')
        return result.returncode == 0 and result.stdout.strip() == 'install ok installed'

    @contextmanager
    def inhibit_services(self):
        # Rename the original entry, including symlinks, rather than copying its target.
        # Temporary masks block systemd activation during package maintenance.
        paths = [self.root / 'usr/sbin/policy-rc.d']
        paths += [self.root / 'etc/systemd/system' / unit for unit in
                  ('docker.service', 'docker.socket', 'containerd.service')]
        def startup_links():
            etc = self.root / 'etc'
            return {path for pattern in ('systemd/system/**/*.wants/docker.*',
                                         'systemd/system/**/*.wants/containerd.service',
                                         'rc*.d/*docker', 'rc*.d/*containerd')
                    for path in etc.glob(pattern) if path.is_symlink()}
        prior_links = startup_links()
        backups = []
        handlers = {}
        def cancel(signum, frame):
            raise SystemExit(128 + signum)
        try:
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                handlers[signum] = signal.signal(signum, cancel)
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                # A sibling directory keeps backups on the same filesystem.
                scratch = Path(tempfile.mkdtemp(prefix='.dotfiles-policy-', dir=path.parent))
                backup = scratch / 'original'
                existed = os.path.lexists(path)
                if existed:
                    path.rename(backup)
                backups.append((path, backup, existed))
                if path.name == 'policy-rc.d':
                    path.write_text('#!/bin/sh\nexit 101\n')
                    path.chmod(0o755)
                else:
                    path.symlink_to('/dev/null')
            yield
        finally:
            # Ignore a second ordinary cancellation until the original policy is back.
            for signum in handlers:
                signal.signal(signum, signal.SIG_IGN)
            try:
                # Native init helpers can add legacy boot links despite policy-rc.d.
                # Remove only transaction-created runtime links; retain all prior links.
                for link in startup_links() - prior_links:
                    link.unlink()
                for path, backup, existed in reversed(backups):
                    if os.path.lexists(path):
                        path.unlink()
                    if existed:
                        backup.rename(path)
                    backup.parent.rmdir()
                if self.root == Path('/') and Path('/run/systemd/system').is_dir():
                    self.command(['systemctl', 'daemon-reload'])
            finally:
                for signum, handler in handlers.items():
                    signal.signal(signum, handler)

    def install_missing(self, packages):
        missing = [package for package in packages if not self.installed(package)]
        if missing:
            self.command(['apt-get', 'install', '--yes', '--no-remove', '--no-upgrade', '--', *missing])

    def verify_candidate(self, package, repo):
        policy = self.command(['apt-cache', 'policy', package], text=True).stdout
        candidate = next((line.split(':', 1)[1].strip() for line in policy.splitlines()
                          if line.strip().startswith('Candidate:')), None)
        if not candidate or candidate == '(none)':
            raise ProvisionError(f'No authenticated candidate for {package}; check the vendor repository.')
        in_candidate = False
        origins = []
        for line in policy.splitlines():
            fields = line.split()
            if not fields:
                continue
            if fields[0] == '***':
                fields = fields[1:]
            if len(fields) == 2 and fields[1].lstrip('-').isdigit():
                in_candidate = fields[0] == candidate
            elif in_candidate and len(fields) > 1 and fields[0].lstrip('-').isdigit():
                if fields[1] != '/var/lib/dpkg/status':
                    origins.append(fields[1].rstrip('/'))
        if not origins or any(origin != repo['uri'].rstrip('/') for origin in origins):
            raise ProvisionError(f'Conflicting candidate source for {package}; expected {repo["uri"]}.')

    def fingerprints(self, key, home):
        result = self.command(['gpg', '--homedir', str(home), '--batch', '--with-colons', '--show-keys', str(key)], text=True)
        primary = False
        fingerprints = []
        for line in result.stdout.splitlines():
            fields = line.split(':')
            if fields[0] in ('pub', 'sub'):
                primary = fields[0] == 'pub'
            elif fields[0] == 'fpr' and primary:
                fingerprints.append(fields[9])
                primary = False
        return fingerprints

    def repository_paths(self, repo):
        name = repo['name']
        # Use native names so package postinst scripts do not add duplicate sources.
        key = self.root / f'usr/share/keyrings/{name}-archive-keyring.gpg'
        if name == 'google-chrome':
            key = self.root / 'usr/share/keyrings/google-chrome.gpg'
        if name == 'claude-desktop':
            key = key.with_suffix('.asc')
        source = self.root / f'etc/apt/sources.list.d/{name}.list'
        if name in ('chatgpt', 'docker', 'google-chrome'):
            source = source.with_suffix('.sources')
        key_native = '/' + str(key.relative_to(self.root))
        if source.suffix == '.sources':
            content = (f'Types: deb\nURIs: {repo["uri"]}\nSuites: {repo["suite"]}\n'
                       f'Components: {repo.get("component", "main")}\nArchitectures: amd64\nSigned-By: {key_native}\n')
            if name == 'google-chrome':
                content = ('### THIS FILE IS AUTOMATICALLY CONFIGURED ###\n'
                           '# Changes to this file will not be preserved.\n'
                           '# This file will not be recreated if removed.\nX-Repolib-Name: Google Chrome\n' + content)
            if name == 'chatgpt':
                content = ('### THIS FILE IS AUTOMATICALLY CONFIGURED ###\n'
                           '# Remove it to opt out of automatic package updates.\nX-Repolib-Name: ChatGPT\n' + content)
        else:
            content = (f'deb [arch=amd64 signed-by={key_native}] {repo["uri"]} '
                       f'{repo["suite"]} {repo.get("component", "main")}\n')
        return key, source, content

    @staticmethod
    def source_identity(content, deb822):
        lines = [line.strip() for line in content.splitlines()
                 if line.strip() and not line.lstrip().startswith('#')]
        if deb822:
            return sorted(tuple(' '.join(part.split()) for part in line.split(':', 1))
                          for line in lines if not line.startswith('X-Repolib-Name:'))
        return [' '.join(line.split()) for line in lines]

    def check_sources(self, repo):
        key, source, content = self.repository_paths(repo)
        if source.is_symlink() or (source.exists() and self.source_identity(source.read_text(), source.suffix == '.sources') !=
                                     self.source_identity(content, source.suffix == '.sources')):
            raise ProvisionError(f'Conflicting APT source {source}; reconcile it manually before applying.')
        candidates = [self.root / 'etc/apt/sources.list']
        directory = self.root / 'etc/apt/sources.list.d'
        if directory.exists():
            candidates += list(directory.glob('*.list')) + list(directory.glob('*.sources'))
        authority = repo['uri'].split('://', 1)[1].rstrip('/')
        for candidate in candidates:
            if candidate != source and candidate.is_file():
                active = '\n'.join(line for line in candidate.read_text().splitlines()
                                   if not line.lstrip().startswith('#'))
                if authority in active:
                    raise ProvisionError(f'Conflicting repository entry in {candidate}; reconcile it with {source}.')
        if key.is_symlink():
            raise ProvisionError(f'Conflicting signing-key symlink {key}; reconcile it manually.')

    def repository(self, repo, scratch):
        key, source, content = self.repository_paths(repo)
        verification = scratch / repo['name']
        verification.mkdir(mode=0o700)
        downloaded = verification / 'downloaded-key'
        self.command(['curl', '--proto', '=https', '--tlsv1.2', '--fail', '--silent', '--show-error',
                      '--location', '--output', str(downloaded), repo['key_url']])
        expected = repo['fingerprint']
        if expected not in self.fingerprints(downloaded, verification):
            raise ProvisionError(f'{repo["name"]} signing-key fingerprint mismatch; no key or source was replaced.')
        if key.exists() and self.fingerprints(key, verification) != [expected]:
            raise ProvisionError(f'Conflicting signing key {key}; reconcile it manually.')
        self.command(['gpg', '--homedir', str(verification), '--batch', '--import', str(downloaded)])
        args = ['gpg', '--homedir', str(verification), '--batch']
        if key.suffix == '.asc':
            args += ['--armor']
        exported = self.command([*args, '--export', expected]).stdout
        if not exported:
            raise ProvisionError(f'Cannot export authenticated key for {repo["name"]}.')
        # Refresh expiring signatures only after authenticating the same primary key.
        key.parent.mkdir(parents=True, exist_ok=True)
        key.write_bytes(exported)
        key.chmod(0o644)
        source.parent.mkdir(parents=True, exist_ok=True)
        if not source.exists():
            source.write_text(content)
            source.chmod(0o644)


def provision(config, *, installer=None, report=None):
    report = inspect_host() if report is None else report
    if not report['supported']:
        raise ProvisionError(' '.join(report['blockers']))
    installer = installer or Installer()
    conflicts = ('docker.io', 'docker-compose', 'docker-compose-v2', 'docker-doc',
                 'docker-buildx', 'podman-docker', 'containerd', 'runc')
    for package in conflicts:
        if installer.installed(package):
            raise ProvisionError(f'Conflicting runtime package {package}; resolve manually without removing active work.')
    for repo in config['repositories']:
        installer.check_sources(repo)
    with installer.inhibit_services(), tempfile.TemporaryDirectory(prefix='dotfiles-linux-apps-') as scratch:
        installer.command(['apt-get', 'update'])
        installer.install_missing(config['packages'])
        for repo in config['repositories']:
            installer.repository(repo, Path(scratch))
        installer.command(['apt-get', 'update'])
        # APT verifies package hashes against signed metadata; use declared identities only.
        for repo in config['repositories']:
            for package in repo['packages']:
                if not installer.installed(package):
                    installer.verify_candidate(package, repo)
        installer.install_missing([package for repo in config['repositories'] for package in repo['packages']])


def main():
    if sys.argv[1:] == ['--inspect']:
        print(json.dumps(inspect_host()))
        return
    config = json.loads(sys.argv[1])
    report = inspect_host()
    if not report['supported']:
        raise ProvisionError(' '.join(report['blockers']))
    if os.geteuid() != 0:
        os.execvp('sudo', ['sudo', sys.executable, str(Path(__file__).resolve()), sys.argv[1]])
    provision(config, report=report)


if __name__ == '__main__':
    try:
        main()
    except (ProvisionError, subprocess.CalledProcessError, OSError) as error:
        print(f'Linux applications: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode() if isinstance(error.stderr, bytes) else error.stderr, file=sys.stderr)
        raise SystemExit(1)
