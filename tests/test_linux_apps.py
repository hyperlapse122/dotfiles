import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_apps', REPO / 'scripts/linux-apps.py')
apps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apps)
CONFIG = json.loads((REPO / 'home/.chezmoidata/linux.yaml').read_text())['linux']
PINNED_RELEASE = 45
UNPINNED_RELEASE = 46


def supported(release=PINNED_RELEASE):
    return {'supported': True, 'blockers': [], 'release': {'host': release}}


def declared(name, config=CONFIG):
    return next(repo for repo in config['repositories'] if repo['name'] == name)


@unittest.skipIf(os.name == 'nt', 'Linux repository fixtures require POSIX symlinks')
class LinuxAppsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.repos = self.root / 'etc/yum.repos.d'
        self.calls = []
        self.installed = set()
        self.candidates = {}
        self.bad_key = False
        self.config = CONFIG
        self.release = PINNED_RELEASE
        self.chrome_install_state = None
        self.installer = apps.Installer(root=self.root, run=self.run_command)

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        stdout = b''
        if args[0] == 'rpm':
            return subprocess.CompletedProcess(args, 0 if args[-1] in self.installed else 1, '', '')
        if args[:2] == ['dnf', 'install']:
            names = args[3:]
            if 'google-chrome-stable' in names:
                defaults = self.root / 'etc/default/google-chrome'
                self.chrome_install_state = ((self.repos / 'google-chrome.repo').is_file(),
                                             defaults.read_text() if defaults.is_file() else None)
            self.installed.update(names)
        if args[:2] == ['dnf', 'repoquery']:
            package = args[-1]
            repo = next(r for r in self.config['repositories'] if package in r['packages'])
            stdout = self.candidates.get(package, repo.get('id', repo['name'])) + '\n'
        if args[0] == 'curl':
            Path(args[args.index('--output') + 1]).write_bytes(b'fixture key')
        if args[0] == 'gpg':
            if '--show-keys' in args:
                repo = declared(Path(args[2]).name, self.config)
                fingerprint = repo.get('fingerprint') or repo['fingerprints'][str(self.release)]
                if self.bad_key:
                    fingerprint = '0' * 40
                stdout = f'pub:::::::::\nfpr:::::::::{fingerprint}:\nsub:::::::::\nfpr:::::::::SUBKEY:\n'
            if '--export' in args:
                stdout = b'authenticated exported key'
        return subprocess.CompletedProcess(args, 0, stdout, b'')

    def provision(self, report=None, **kwargs):
        report = supported(self.release) if report is None else report
        apps.provision(self.config, installer=self.installer, report=report, **kwargs)

    def paths(self, name):
        return self.installer.repository_paths(apps.resolve(declared(name, self.config), self.release))

    def installs(self):
        return [c for c in self.calls if c[:2] == ['dnf', 'install']]

    def test_fresh_install_orders_host_packages_before_authenticated_vendor_packages(self):
        self.provision()
        transactions = self.installs()
        self.assertEqual(len(transactions), 2)
        self.assertEqual(transactions[0], ['dnf', 'install', '--assumeyes', *CONFIG['packages']])
        self.assertEqual(sorted(transactions[1][3:]),
                         sorted(p for repo in CONFIG['repositories'] for p in repo['packages']))
        first_key = next(i for i, c in enumerate(self.calls) if c[0] == 'gpg')
        self.assertLess(self.calls.index(transactions[0]), first_key)
        for transaction in transactions:
            self.assertFalse({'upgrade', 'remove', '--allowerasing', '--best'} & set(transaction))
        for repo in CONFIG['repositories']:
            key, source, content = self.paths(repo['name'])
            self.assertEqual(source.read_text(), content)
            self.assertIn('gpgcheck=1\n', content)
            self.assertIn(f'gpgkey=file:///etc/pki/rpm-gpg/{key.name}\n', content)
            self.assertEqual(key.parent, self.root / 'etc/pki/rpm-gpg')
            self.assertEqual(key.read_bytes(), b'authenticated exported key')

    def test_no_command_starts_a_unit_a_runtime_or_linger(self):
        self.provision()
        self.assertFalse(any(c[0] in ('systemctl', 'loginctl', 'podman', 'docker', 'minikube') for c in self.calls))
        self.assertFalse(any('enable' in c or 'enable-linger' in c or 'start' in c for c in self.calls))

    def test_repeat_preserves_unrelated_repositories_and_installs_nothing(self):
        unrelated = self.repos / 'unrelated.repo'
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text('[unrelated]\nbaseurl=https://example.invalid\n')
        self.provision()
        self.calls.clear()
        self.provision()
        self.assertEqual(self.installs(), [])
        self.assertEqual(unrelated.read_text(), '[unrelated]\nbaseurl=https://example.invalid\n')
        self.assertFalse(any('upgrade' in c for c in self.calls))

    def test_declaration_targets_fedora_kde_with_podman_and_no_docker_engine(self):
        packages = set(CONFIG['packages'])
        self.assertTrue({'gnupg2', 'pinentry-qt', 'gcc-c++', 'pkgconf-pkg-config', 'xz', 'libsecret',
                         'shadow-utils', 'podman', 'podman-docker', 'podman-compose', 'passt',
                         'edk2-ovmf'} <= packages)
        self.assertFalse({'ghostty', 'xdg-terminal-exec', 'pinentry-gnome3', 'build-essential'} & packages)
        self.assertEqual([repo['name'] for repo in CONFIG['repositories']],
                         ['google-chrome', '1password', 'chatgpt', 'mise', 'terra'])
        vendor_packages = {p for repo in CONFIG['repositories'] for p in repo['packages']}
        self.assertFalse({'claude-desktop', 'docker-ce', 'docker-ce-cli'} & vendor_packages)
        for repo in CONFIG['repositories']:
            self.assertFalse({'uri', 'suite', 'component'} & set(repo))

    def test_unsupported_hosts_never_run_package_commands(self):
        for blocker in ('Requires Linux.', 'Requires Fedora; other distributions are unsupported.',
                        'Requires native RPM architecture x86_64.'):
            with self.subTest(blocker=blocker), self.assertRaisesRegex(apps.ProvisionError, blocker):
                self.provision({'supported': False, 'blockers': [blocker]})
        self.assertEqual(self.calls, [])

    def test_installed_docker_engine_fails_before_any_transaction(self):
        for package in ('docker-ce', 'docker-ce-cli', 'moby-engine', 'docker'):
            with self.subTest(package=package):
                self.installed = {package}
                with self.assertRaisesRegex(apps.ProvisionError, f'Docker engine package {package}.*manually'):
                    self.provision()
        self.assertFalse(any(c[0] == 'dnf' for c in self.calls))
        self.assertFalse(self.repos.exists())

    def test_differing_repository_file_is_not_overwritten(self):
        _, source, _ = self.paths('1password')
        source.parent.mkdir(parents=True)
        source.write_text('[1password]\nbaseurl=https://example.invalid\n')
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting repository file .*1password.repo'):
            self.provision()
        self.assertEqual(source.read_text(), '[1password]\nbaseurl=https://example.invalid\n')
        self.assertFalse(any(c[0] == 'dnf' for c in self.calls))

    def test_foreign_file_naming_the_same_base_url_is_reported(self):
        foreign = self.repos / 'local-chrome.repo'
        foreign.parent.mkdir(parents=True)
        foreign.write_text(f'[chrome]\nbaseurl={declared("google-chrome")["baseurl"]}\n')
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting repository entry in .*local-chrome.repo'):
            self.provision()
        self.assertFalse((self.repos / 'google-chrome.repo').exists())

    def test_bad_downloaded_key_never_becomes_trusted(self):
        self.bad_key = True
        with self.assertRaisesRegex(apps.ProvisionError, 'fingerprint mismatch'):
            self.provision()
        key, source, _ = self.paths(CONFIG['repositories'][0]['name'])
        self.assertFalse(key.exists())
        self.assertFalse(source.exists())

    def test_existing_key_with_another_fingerprint_is_preserved(self):
        key, _, _ = self.paths('google-chrome')
        key.parent.mkdir(parents=True)
        key.write_bytes(b'previous key')
        original = self.installer.fingerprints
        self.installer.fingerprints = lambda path, home: ['wrong'] if path == key else original(path, home)
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting signing key'):
            self.provision()
        self.assertEqual(key.read_bytes(), b'previous key')

    def test_symlinked_key_is_reported_by_name(self):
        key, _, _ = self.paths('chatgpt')
        key.parent.mkdir(parents=True)
        key.symlink_to('/dev/null')
        with self.assertRaisesRegex(apps.ProvisionError, f'signing-key symlink .*{key.name}'):
            self.provision()
        self.assertTrue(key.is_symlink())
        self.assertFalse(any(c[0] == 'dnf' for c in self.calls))

    def test_candidate_from_another_repository_is_rejected(self):
        self.candidates['1password'] = 'fedora'
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting candidate source for 1password'):
            self.provision()
        self.assertEqual(len(self.installs()), 1)
        self.assertNotIn('1password', self.installed)

    def test_terra_names_the_pinned_release_and_filters_to_ghostty(self):
        self.provision()
        key, source, _ = self.paths('terra')
        content = source.read_text()
        self.assertIn('baseurl=https://repos.fyralabs.com/terra45\n', content)
        self.assertIn('includepkgs=ghostty*\n', content)
        self.assertNotIn('$releasever', content)
        self.assertEqual(key.name, 'RPM-GPG-KEY-terra45-C2AC02124AF114F086592E3C8DDE7D14C1C23D8C.asc')
        self.assertIn(['curl', 'https://repos.fyralabs.com/terra45/key.asc'],
                      [[c[0], c[-1]] for c in self.calls])
        self.assertIn('ghostty', self.installed)

    def test_terra_without_a_pin_is_not_written_and_other_repositories_install(self):
        self.release = UNPINNED_RELEASE
        with self.assertRaisesRegex(apps.ProvisionError, 'No terra signing-key fingerprint is pinned for Fedora 46'):
            self.provision()
        self.assertFalse((self.repos / 'terra.repo').exists())
        self.assertFalse(any('fyralabs' in c[-1] for c in self.calls if c[0] == 'curl'))
        self.assertTrue({'google-chrome-stable', '1password', '1password-cli', 'chatgpt', 'mise'} <= self.installed)
        self.assertNotIn('ghostty', self.installed)

    def test_terra_without_a_pin_keeps_an_installed_ghostty(self):
        self.provision()
        before = (self.repos / 'terra.repo').read_text()
        self.release = UNPINNED_RELEASE
        self.calls.clear()
        self.provision()
        self.assertEqual((self.repos / 'terra.repo').read_text(), before)
        self.assertEqual(self.installs(), [])

    def test_terra_file_for_an_older_release_is_rewritten_once_the_host_release_is_pinned(self):
        self.provision()
        old_key, source, _ = self.paths('terra')
        self.config = copy.deepcopy(CONFIG)
        declared('terra', self.config)['fingerprints'][str(UNPINNED_RELEASE)] = 'A' * 40
        self.release = UNPINNED_RELEASE
        self.bad_key = True
        with self.assertRaisesRegex(apps.ProvisionError, 'fingerprint mismatch'):
            self.provision()
        self.assertIn('terra45', source.read_text())
        self.bad_key = False
        self.provision()
        new_key, source, content = self.paths('terra')
        self.assertEqual(source.read_text(), content)
        self.assertIn('baseurl=https://repos.fyralabs.com/terra46\n', content)
        self.assertEqual(new_key.name, 'RPM-GPG-KEY-terra46-' + 'A' * 40 + '.asc')
        self.assertTrue(new_key.is_file())
        self.assertTrue(old_key.is_file())

    def test_terra_file_with_any_other_difference_is_not_overwritten(self):
        self.provision()
        _, source, content = self.paths('terra')
        widened = content.replace('includepkgs=ghostty*\n', '')
        source.write_text(widened)
        self.config = copy.deepcopy(CONFIG)
        declared('terra', self.config)['fingerprints'][str(UNPINNED_RELEASE)] = 'A' * 40
        for release in (PINNED_RELEASE, UNPINNED_RELEASE):
            with self.subTest(release=release):
                self.release = release
                with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting repository file .*terra.repo'):
                    self.provision()
                self.assertEqual(source.read_text(), widened)

    def test_chrome_repository_and_defaults_exist_before_chrome_installs(self):
        self.provision()
        self.assertEqual(self.chrome_install_state, (True, 'repo_add_once="false"\n'))

    def test_existing_chrome_defaults_are_left_unchanged(self):
        defaults = self.root / 'etc/default/google-chrome'
        defaults.parent.mkdir(parents=True)
        defaults.write_text('repo_add_once="true"\n')
        self.provision()
        self.assertEqual(self.chrome_install_state, (True, 'repo_add_once="true"\n'))

    def test_chatgpt_repository_matches_the_file_the_vendor_package_ships(self):
        self.provision()
        self.assertEqual((self.repos / 'chatgpt.repo').read_text(), (
            '[openai-chatgpt]\n'
            'name=ChatGPT\n'
            'baseurl=https://persistent.oaistatic.com/codex-app-prod/linux/rpm/$basearch\n'
            'enabled=1\n'
            'type=rpm-md\n'
            'gpgcheck=1\n'
            'repo_gpgcheck=1\n'
            'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-chatgpt-3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4.asc\n'))
        self.assertTrue((self.root / 'etc/pki/rpm-gpg/'
                         'RPM-GPG-KEY-chatgpt-3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4.asc').is_file())

    def test_single_repository_mode_writes_and_installs_only_that_repository(self):
        for _ in range(2):
            self.provision(repository='mise')
        self.assertEqual(self.installs(), [['dnf', 'install', '--assumeyes', 'mise']])
        self.assertEqual([path.name for path in self.repos.iterdir()],
                         ['_copr:copr.fedorainfracloud.org:jdxcode:mise.repo'])
        self.assertIn('baseurl=https://download.copr.fedorainfracloud.org/results/jdxcode/mise/'
                      'fedora-$releasever-$basearch/\n', next(self.repos.iterdir()).read_text())
        with self.assertRaisesRegex(apps.ProvisionError, 'Unknown repository absent'):
            self.provision(repository='absent')


@unittest.skipUnless(shutil.which('chezmoi'), 'Chezmoi required')
class LinuxAppsHookTest(unittest.TestCase):
    def test_rendered_hook_quotes_source_and_data_without_applying(self):
        with tempfile.TemporaryDirectory(prefix="linux apps ' ") as scratch:
            root = Path(scratch)
            config = root / 'chezmoi.toml'
            config.write_text('')
            for operating_system in ('linux', 'darwin', 'windows'):
                context = {'chezmoi': {'os': operating_system, 'workingTree': str(root)}, 'linux': CONFIG}
                template = (REPO / 'home/.chezmoiscripts/run_before_12-install-linux-apps.sh.tmpl').read_text()
                wrapper = ('{{ template "subject" (' + json.dumps(json.dumps(context)) + ' | fromJson) }}'
                           '{{ define "subject" }}' + template + '{{ end }}')
                result = subprocess.run(['chezmoi', '--source', str(REPO / 'home'), '--config', str(config),
                                         'execute-template'], input=wrapper, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if operating_system != 'linux':
                    self.assertEqual(result.stdout.strip(), '')
                else:
                    import shlex
                    command = next(line for line in result.stdout.splitlines() if line.startswith('exec '))
                    args = shlex.split(command)
                    self.assertEqual(args[3], str(root))
                    self.assertEqual(args[-2], str(root / 'scripts/linux-apps.py'))
                    self.assertEqual(json.loads(args[-1]), CONFIG)


if __name__ == '__main__':
    unittest.main()
