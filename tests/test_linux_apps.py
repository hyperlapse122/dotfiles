import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_apps', REPO / 'scripts/linux-apps.py')
apps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apps)
CONFIG = json.loads((REPO / 'home/.chezmoidata/linux.yaml').read_text())['linux']
SUPPORTED = {'supported': True, 'blockers': []}


@unittest.skipIf(os.name == "nt", "Linux startup-policy fixtures require POSIX symlink and signal semantics")
class LinuxAppsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.calls = []
        self.installed = set()
        self.bad_key = False
        self.fail_install = False
        self.cancel_install = False
        self.installer = apps.Installer(root=self.root, run=self.run_command)

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        stdout = b''
        if args[0] == 'dpkg-query':
            installed = args[-1] in self.installed
            return subprocess.CompletedProcess(args, 0 if installed else 1,
                                               'install ok installed' if installed else '', '')
        if args[0] == 'apt-get':
            policy = self.root / 'usr/sbin/policy-rc.d'
            self.assertEqual(policy.read_text(), '#!/bin/sh\nexit 101\n')
            for unit in ('docker.service', 'docker.socket', 'containerd.service'):
                self.assertEqual(os.readlink(self.root / 'etc/systemd/system' / unit), '/dev/null')
            if args[1] == 'install':
                if self.fail_install:
                    raise subprocess.CalledProcessError(100, args, stderr=b'fixture apt failure')
                if self.cancel_install:
                    os.kill(os.getpid(), signal.SIGTERM)
                self.installed.update(args[args.index('--') + 1:])
        if args[0] == 'curl':
            Path(args[args.index('--output') + 1]).write_bytes(b'fixture key')
        if args[0] == 'apt-cache':
            repo = next(r for r in CONFIG['repositories'] if args[-1] in r['packages'])
            stdout = f"{args[-1]}:\n  Candidate: 1.0\n  Version table:\n     1.0 500\n        500 {repo['uri']} stable/main amd64 Packages\n"
        if args[0] == 'gpg':
            if '--show-keys' in args:
                name = Path(args[2]).name
                repo = next(r for r in CONFIG['repositories'] if r['name'] == name)
                fingerprint = '0' * 40 if self.bad_key else repo['fingerprint']
                stdout = f'pub:::::::::\nfpr:::::::::{fingerprint}:\nsub:::::::::\nfpr:::::::::SUBKEY:\n'
            if '--export' in args:
                stdout = b'authenticated exported key'
        return subprocess.CompletedProcess(args, 0, stdout, b'')

    def provision(self, report=SUPPORTED):
        apps.provision(CONFIG, installer=self.installer, report=report)

    def test_fresh_install_orders_prerequisites_before_authenticated_vendor_packages(self):
        self.provision()
        transactions = [c for c in self.calls if c[:2] == ['apt-get', 'install']]
        self.assertEqual(len(transactions), 2)
        self.assertIn('build-essential', transactions[0])
        self.assertIn('libsecret-1-0', transactions[0])
        self.assertIn('docker-ce-rootless-extras', transactions[1])
        self.assertIn('1password-cli', transactions[1])
        self.assertIn('chatgpt', transactions[1])
        self.assertNotIn('golang-docker-credential-helpers', transactions[0])
        first_key = next(i for i, c in enumerate(self.calls) if c[0] == 'gpg')
        self.assertLess(self.calls.index(transactions[0]), first_key)
        self.assertFalse(any(c[0] in ('systemctl', 'docker', 'minikube', 'dockerd-rootless-setuptool.sh') for c in self.calls))
        self.assertFalse((self.root / 'usr/sbin/policy-rc.d').exists())
        for repo in CONFIG['repositories']:
            key, source, content = self.installer.repository_paths(repo)
            self.assertEqual(source.read_text(), content)
            self.assertEqual(key.read_bytes(), b'authenticated exported key')
        self.assertFalse(list(self.root.rglob('.dotfiles-policy-*')))

    def test_repeat_preserves_unrelated_sources_and_does_not_upgrade_installed_apps(self):
        source = self.root / 'etc/apt/sources.list.d/unrelated.sources'
        source.parent.mkdir(parents=True)
        source.write_text('Types: deb\nURIs: https://example.invalid\n')
        self.provision()
        self.calls.clear()
        self.provision()
        self.assertFalse(any(c[:2] == ['apt-get', 'install'] for c in self.calls))
        self.assertEqual(source.read_text(), 'Types: deb\nURIs: https://example.invalid\n')
        self.assertFalse(any('upgrade' in c or 'dist-upgrade' in c for c in self.calls))

    def test_declared_packages_target_the_gnome_workstation(self):
        declared = CONFIG['packages']
        self.assertTrue({'pinentry-gnome3', 'xdg-terminal-exec'} <= set(declared))
        self.assertNotIn('pinentry-qt', declared)

    def test_unsupported_hosts_never_run_package_commands(self):
        for blocker in ('Requires Linux.', 'Requires Ubuntu Desktop 26.04.', 'Requires amd64.'):
            with self.subTest(blocker=blocker), self.assertRaisesRegex(apps.ProvisionError, blocker):
                self.provision({'supported': False, 'blockers': [blocker]})
        self.assertEqual(self.calls, [])

    def test_conflicting_runtime_fails_before_transaction(self):
        self.installed.add('docker.io')
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting runtime package docker.io'):
            self.provision()
        self.assertFalse(any(c[0] == 'apt-get' for c in self.calls))

    def test_conflicting_source_is_not_overwritten(self):
        _, source, _ = self.installer.repository_paths(CONFIG['repositories'][0])
        source.parent.mkdir(parents=True)
        source.write_text('local source\n')
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting APT source'):
            self.provision()
        self.assertEqual(source.read_text(), 'local source\n')
        self.assertFalse(any(c[0] == 'apt-get' for c in self.calls))

    def test_duplicate_vendor_source_is_not_overwritten(self):
        source = self.root / 'etc/apt/sources.list'
        source.parent.mkdir(parents=True)
        source.write_text('deb https://download.docker.com/linux/ubuntu noble stable\n')
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting repository entry'):
            self.provision()
        self.assertIn('noble', source.read_text())

    def test_bad_downloaded_key_never_becomes_trusted(self):
        self.bad_key = True
        with self.assertRaisesRegex(apps.ProvisionError, 'fingerprint mismatch'):
            self.provision()
        key, source, _ = self.installer.repository_paths(CONFIG['repositories'][0])
        self.assertFalse(key.exists())
        self.assertFalse(source.exists())
        self.assertFalse((self.root / 'usr/sbin/policy-rc.d').exists())

    def test_existing_conflicting_key_is_preserved(self):
        key, _, _ = self.installer.repository_paths(CONFIG['repositories'][0])
        key.parent.mkdir(parents=True)
        key.write_bytes(b'previous key')
        original = self.installer.fingerprints
        self.installer.fingerprints = lambda path, home: ['wrong'] if path == key else original(path, home)
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting signing key'):
            self.provision()
        self.assertEqual(key.read_bytes(), b'previous key')

    def test_foreign_candidate_is_rejected(self):
        original = self.installer.command
        def command(args, **kwargs):
            result = original(args, **kwargs)
            if args[0] == 'apt-cache':
                result.stdout = result.stdout.replace(CONFIG['repositories'][0]['uri'], 'https://unrelated.invalid')
            return result
        self.installer.command = command
        with self.assertRaisesRegex(apps.ProvisionError, 'Conflicting candidate source'):
            self.provision()
        transactions = [c for c in self.calls if c[:2] == ['apt-get', 'install']]
        self.assertEqual(len(transactions), 1)

    def test_policy_file_and_symlink_restored_on_success_failure_and_cancellation(self):
        for kind in ('file', 'symlink', 'absent'):
            for outcome in ('success', 'failure', 'cancel'):
                with self.subTest(kind=kind, outcome=outcome):
                    policy = self.root / 'usr/sbin/policy-rc.d'
                    policy.parent.mkdir(parents=True, exist_ok=True)
                    if os.path.lexists(policy):
                        policy.unlink()
                    if kind == 'file':
                        policy.write_bytes(b'original policy\n')
                        policy.chmod(0o751)
                    if kind == 'symlink':
                        policy.symlink_to('existing-policy')
                    self.installed.clear()
                    self.fail_install = outcome == 'failure'
                    self.cancel_install = outcome == 'cancel'
                    if outcome == 'success':
                        self.provision()
                    else:
                        with self.assertRaises((subprocess.CalledProcessError, SystemExit)):
                            self.provision()
                    if kind == 'file':
                        self.assertEqual(policy.read_bytes(), b'original policy\n')
                        self.assertEqual(policy.stat().st_mode & 0o777, 0o751)
                    elif kind == 'symlink':
                        self.assertEqual(os.readlink(policy), 'existing-policy')
                    else:
                        self.assertFalse(os.path.lexists(policy))
                    self.assertFalse(list(self.root.rglob('.dotfiles-policy-*')))

    def test_only_new_runtime_boot_links_are_removed(self):
        directory = self.root / 'etc/systemd/system/multi-user.target.wants'
        directory.mkdir(parents=True)
        existing = directory / 'docker.service'
        existing.symlink_to('/lib/systemd/system/docker.service')
        unrelated = directory / 'other.service'
        unrelated.symlink_to('/lib/systemd/system/other.service')
        prior = self.root / 'etc/systemd/system/containerd.service'
        prior.write_bytes(b'local override')
        prior.chmod(0o640)
        with self.installer.inhibit_services():
            created = directory / 'containerd.service'
            created.symlink_to('/lib/systemd/system/containerd.service')
        self.assertTrue(existing.is_symlink())
        self.assertTrue(unrelated.is_symlink())
        self.assertFalse(created.is_symlink())
        self.assertEqual(prior.read_bytes(), b'local override')
        self.assertEqual(prior.stat().st_mode & 0o777, 0o640)


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
