"""Missing-only native Fedora packages and signed vendor repositories, invoked by explicit application.

Standard library only: provisioning runs the single-repository mode with the
system python3 before mise exists.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


DOCKER_ENGINES = ('docker-ce', 'docker-ce-cli', 'moby-engine', 'docker')


def inspect_host(**kwargs):
    spec = importlib.util.spec_from_file_location('linux_platform', Path(__file__).with_name('linux-platform.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.inspect_host(**kwargs)


class ProvisionError(RuntimeError):
    pass


def identity(content):
    return '\n'.join(line.strip() for line in content.splitlines()
                     if line.strip() and not line.lstrip().startswith('#'))


class Installer:
    def __init__(self, *, root=Path('/'), run=subprocess.run):
        self.root = Path(root)
        self.run = run

    def command(self, args, **kwargs):
        return self.run(args, check=True, capture_output=True, **kwargs)

    def installed(self, package):
        result = self.run(['rpm', '-q', package], capture_output=True, text=True, check=False)
        if result.returncode not in (0, 1):
            raise ProvisionError(f'Cannot inspect installed package {package}.')
        return result.returncode == 0

    def install_missing(self, packages):
        missing = [package for package in packages if not self.installed(package)]
        if missing:
            self.command(['dnf', 'install', '--assumeyes', *missing])

    def verify_candidate(self, package, repo):
        repo_id = repo.get('id', repo['name'])
        # --assumeyes lets dnf import the already authenticated key for signed metadata.
        listing = self.command(['dnf', 'repoquery', '--assumeyes', '--quiet', '--latest-limit=1',
                                '--queryformat', '%{repoid}\n', package], text=True).stdout
        origins = set(listing.split())
        if not origins:
            raise ProvisionError(f'No candidate for {package}; check the {repo["name"]} repository.')
        if origins != {repo_id}:
            raise ProvisionError(f'Conflicting candidate source for {package}; expected repository {repo_id}.')

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
        # Declared file names, repository IDs and key paths match what the vendor's own
        # package writes, so installing that package leaves one source in place.
        key = self.root / f'etc/pki/rpm-gpg/RPM-GPG-KEY-{name}-{repo["fingerprint"]}.asc'
        source = self.root / 'etc/yum.repos.d' / repo.get('file', f'{name}.repo')
        content = (f'[{repo.get("id", name)}]\nname={repo["title"]}\nbaseurl={repo["baseurl"]}\n'
                   'enabled=1\ntype=rpm-md\ngpgcheck=1\n')
        if repo.get('repo_gpgcheck'):
            content += 'repo_gpgcheck=1\n'
        content += f'gpgkey=file:///{key.relative_to(self.root)}\n'
        if repo.get('skip_if_unavailable'):
            # A repository built per Fedora release may not exist yet for a newer release;
            # dnf then skips it instead of failing every transaction.
            content += 'skip_if_unavailable=True\n'
        if 'includepkgs' in repo:
            content += f'includepkgs={repo["includepkgs"]}\n'
        return key, source, content

    def check_sources(self, repo):
        key, source, content = self.repository_paths(repo)
        if os.path.lexists(source):
            existing = source.read_text() if source.is_file() and not source.is_symlink() else None
            if existing is None or identity(existing) != identity(content):
                raise ProvisionError(f'Conflicting repository file {source}; this repository is managed with a pinned '
                                     'signing key. Remove the file (for a COPR, `dnf copr disable` or `dnf copr remove`) '
                                     'or reconcile it manually, then apply again.')
        authority = repo['baseurl'].split('://', 1)[1].rstrip('/')
        for candidate in sorted(source.parent.glob('*.repo')) if source.parent.is_dir() else []:
            if candidate != source and candidate.is_file() and authority in identity(candidate.read_text()):
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
            raise ProvisionError(f'{repo["name"]} signing-key fingerprint mismatch; no key or repository file was replaced.')
        if key.exists() and self.fingerprints(key, verification) != [expected]:
            raise ProvisionError(f'Conflicting signing key {key}; reconcile it manually.')
        self.command(['gpg', '--homedir', str(verification), '--batch', '--import', str(downloaded)])
        exported = self.command(['gpg', '--homedir', str(verification), '--batch', '--armor',
                                 '--export', expected]).stdout
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
        defaults = repo.get('defaults')
        if defaults:
            path = self.root / defaults['path']
            if not os.path.lexists(path):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(defaults['content'])
                path.chmod(0o644)


def provision(config, *, installer=None, report=None, repository=None):
    report = inspect_host() if report is None else report
    if not report['supported']:
        raise ProvisionError(' '.join(report['blockers']))
    installer = installer or Installer()
    packages = config['packages']
    repositories = config['repositories']
    if repository is not None:
        packages = []
        repositories = [repo for repo in repositories if repo['name'] == repository]
        if not repositories:
            raise ProvisionError(f'Unknown repository {repository}.')
    for package in DOCKER_ENGINES:
        if installer.installed(package):
            raise ProvisionError(f'Conflicting Docker engine package {package}; resolve it manually '
                                 'without removing active work.')
    for repo in repositories:
        installer.check_sources(repo)
    installer.install_missing(packages)
    with tempfile.TemporaryDirectory(prefix='dotfiles-linux-apps-') as scratch:
        for repo in repositories:
            installer.repository(repo, Path(scratch))
    for repo in repositories:
        for package in repo['packages']:
            if not installer.installed(package):
                installer.verify_candidate(package, repo)
    installer.install_missing([package for repo in repositories for package in repo['packages']])


def main():
    arguments = sys.argv[1:]
    if arguments == ['--inspect']:
        print(json.dumps(inspect_host()))
        return
    repository = None
    if len(arguments) == 3 and arguments[0] == '--repository':
        repository = arguments[1]
        config = json.loads(Path(arguments[2]).read_text())['linux']
    elif len(arguments) == 1:
        config = json.loads(arguments[0])
    else:
        raise SystemExit('usage: linux-apps.py --inspect | --repository NAME LINUX_YAML | CONFIG_JSON')
    report = inspect_host()
    if not report['supported']:
        raise ProvisionError(' '.join(report['blockers']))
    if os.geteuid() != 0:
        os.execvp('sudo', ['sudo', sys.executable, str(Path(__file__).resolve()), *arguments])
    provision(config, report=report, repository=repository)


if __name__ == '__main__':
    try:
        main()
    except (ProvisionError, subprocess.CalledProcessError, OSError) as error:
        print(f'Linux applications: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode() if isinstance(error.stderr, bytes) else error.stderr, file=sys.stderr)
        raise SystemExit(1)
