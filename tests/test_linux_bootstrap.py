import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import functools, importlib.util, json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['LINUX_TEST_ROOT'])
state = json.loads((root/'state.json').read_text())
name, *args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream: stream.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if name == 'mise' and args == state.get('fail_mise'): sys.exit(23)
source = root/'source with spaces'
def load(path):
    spec = importlib.util.spec_from_file_location(pathlib.Path(path).stem.replace('-', '_'), path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
def inspect():
    module = load(source/'scripts/linux-platform.py')
    run = lambda command, **kwargs: subprocess.CompletedProcess(command, 0, 'x86_64', '')
    release = {'ID': 'fedora', 'VERSION_ID': str(module.VALIDATED_RELEASE), 'VARIANT_ID': state.get('variant', 'kde')}
    return module.inspect_host(system='Linux', os_release=release, environ={}, run=run, ostree_booted=False)
def repositories():
    return json.loads((source/'home/.chezmoidata/linux.yaml').read_text())['linux']['repositories']
def apps(arguments, uid):
    # The real package script runs against a scratch system root; its commands resolve to these fixtures.
    module = load(arguments[0])
    module.inspect_host = inspect
    module.Installer = functools.partial(module.Installer, root=root/'system')
    os.geteuid = lambda: uid
    sys.argv = arguments
    module.main()
if name == 'python3':
    if args[0].endswith('linux-apps.py'): apps(args, 1000)
    else:
        report = inspect()
        print(json.dumps(report)); sys.exit(0 if report['supported'] else 1)
elif name == 'git':
    if args[0] == 'clone': shutil.copytree(root/'source with spaces', args[-1], dirs_exist_ok=True)
    elif args[-2:] == ['--get', 'remote.origin.url']: print(state.get('origin', 'https://github.com/hyperlapse122/dotfiles.git'))
    elif args[-1] == '--show-prefix': print(state.get('prefix', ''))
elif name == 'id': print(state.get('uid', '1000'))
elif name == 'rpm': sys.exit(0 if args[-1] in state.get('packages', []) else 1)
elif name == 'sudo':
    # Never execute privileged commands; model successful package installation only.
    if args[1:2] and args[1].endswith('linux-apps.py'): apps(args[1:], 0)
    elif args[:3] == ['dnf', 'install', '-y']:
        state.setdefault('packages', []).extend(args[3:])
        (root/'state.json').write_text(json.dumps(state))
elif name == 'dnf':
    if args[0] == 'repoquery':
        print(next(repo.get('id', repo['name']) for repo in repositories() if args[-1] in repo['packages']))
    else:
        state.setdefault('packages', []).extend(args[2:])
        if 'mise' in args[2:]: shutil.copy2(root/'mise-template', root/'bin/mise')
        (root/'state.json').write_text(json.dumps(state))
elif name == 'curl': pathlib.Path(args[args.index('--output')+1]).write_text('key')
elif name == 'gpg':
    if '--show-keys' in args:
        repository = pathlib.Path(args[args.index('--homedir')+1]).name
        pinned = next(repo['fingerprint'] for repo in repositories() if repo['name'] == repository)
        print('pub:-:255:22:\nfpr:::::::::'+state.get('key_fingerprint', pinned)+':')
    elif '--export' in args: print('key')
elif name == 'mise':
    if args[:1] == ['trust']: sys.exit()
    if args not in (['install'], ['run', 'bootstrap']): sys.exit('Unexpected mise action')
    command = state['bootstrap_task'].replace('{{config_root}}', pathlib.Path.cwd().as_posix())
    sys.exit(subprocess.run(command, shell=True).returncode)
else: sys.exit('Unexpected command: '+name)
'''


@unittest.skipIf(os.name == 'nt', 'POSIX entry-point fixtures require a POSIX host')
class LinuxBootstrapTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='linux setup ')
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.home = self.root/'home'; self.home.mkdir()
        self.source = self.root/'source with spaces'; self.source.mkdir()
        for name in ('mise.toml', '.chezmoiroot', '.chezmoi-bootstrap.toml',
                     'bootstrap-fedora.sh', 'provision-fedora.sh', 'scripts/linux-platform.py',
                     'scripts/linux-apps.py', 'home/.chezmoidata/linux.yaml'):
            target = self.source/name; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO/name, target)
        (self.source/'.git').mkdir()
        (self.source/'home/dot_fixture').write_text('managed')
        self.fixture = self.root/'fixture.py'; self.fixture.write_text(FIXTURE)
        for name in ('git', 'python3', 'mise', 'id', 'rpm', 'sudo', 'dnf', 'curl', 'gpg'):
            self.wrapper(self.bin/name, name)
        self.wrapper(self.root/'mise-template', 'mise')
        for name in ('dirname', 'ls', 'sh'):
            (self.bin/name).symlink_to(shutil.which(name))
        self.chezmoi = shutil.which('chezmoi')
        if self.chezmoi: (self.bin/'chezmoi').symlink_to(self.chezmoi)
        self.state = {'bootstrap_task': tomllib.loads((REPO/'mise.toml').read_text())['tasks']['bootstrap']['run']}
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': str(self.bin),
                    'LINUX_TEST_ROOT': str(self.root), 'XDG_CONFIG_HOME': str(self.home/'.config'),
                    'XDG_CACHE_HOME': str(self.root/'cache'), 'XDG_DATA_HOME': str(self.root/'data'),
                    'XDG_STATE_HOME': str(self.root/'state'), 'PYTHONDONTWRITEBYTECODE': '1'}
        self.env.pop('BASH_ENV', None); self.env.pop('ENV', None)

    def wrapper(self, path, name):
        path.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' '+shlex.quote(str(self.fixture))+' '+shlex.quote(name)+' "$@"\n')
        path.chmod(0o755)

    def run_script(self, name, *args):
        (self.root/'state.json').write_text(json.dumps(self.state))
        return subprocess.run(['/bin/sh', str(self.source/name), *map(str, args)], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        path = self.root/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_repeat_preparation_ignores_hostile_personal_hooks(self):
        if not self.chezmoi: self.skipTest('Real chezmoi required')
        config = self.home/'.config/chezmoi/chezmoi.toml'; config.parent.mkdir(parents=True)
        marker = self.home/'hook-ran'
        hook = '\ncommand = '+json.dumps(sys.executable)+'\nargs = '+json.dumps(['-c', 'from pathlib import Path; Path('+repr(str(marker))+').touch()'])+'\n'
        text = '[hooks.managed.pre]'+hook+'[hooks.read-source-state.pre]'+hook
        config.write_text(text)
        sentinel = self.home/'existing'; sentinel.write_text('keep')
        for _ in range(2):
            result = self.run_script('bootstrap-fedora.sh', self.source)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('chezmoi --source', result.stdout)
            self.assertNotIn('configure-chezmoi.sh', result.stdout)
            self.assertFalse(marker.exists())
            self.assertFalse((self.home/'.fixture').exists())
            self.assertEqual(config.read_text(), text)
            self.assertEqual(sentinel.read_text(), 'keep')
        self.assertFalse(any(name in ('sudo', 'dnf') for name, _ in self.calls()))
        self.assertEqual([args for name, args in self.calls() if name == 'mise'],
                         [['trust', str(self.source/'mise.toml')], ['install'], ['run', 'bootstrap']]*2)

    def test_unsupported_home_unchanged_for_both_entry_points(self):
        sentinel = self.home/'existing'; sentinel.write_bytes(b'keep')
        self.state['variant'] = 'workstation'
        for name in ('bootstrap-fedora.sh', 'provision-fedora.sh'):
            result = self.run_script(name, self.source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('KDE Plasma Desktop edition', result.stdout+result.stderr)
        self.assertEqual(list(self.home.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b'keep')
        self.assertFalse(any(name in ('sudo', 'dnf', 'mise', 'git') for name, _ in self.calls()))

    def test_destination_guards_precede_preparation(self):
        for override in ({'origin': 'https://example.com/other.git'}, {'prefix': 'subdir/'}, {}):
            with self.subTest(override=override):
                self.state.update(override)
                if not override: (self.source/'.git').rmdir()
                result = self.run_script('bootstrap-fedora.sh', self.source)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(name == 'mise' for name, _ in self.calls()))
                self.state.pop('origin', None); self.state.pop('prefix', None)

    def test_provision_only_installs_missing_prerequisites(self):
        (self.bin/'mise').unlink()
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        calls = self.calls()
        self.assertIn(['sudo', ['dnf', 'install', '-y', 'ca-certificates', 'curl', 'git', 'gnupg2', 'xz', 'bzip2', 'unzip']], calls)
        self.assertTrue((self.root/'system/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:jdxcode:mise.repo').is_file())
        key_download = next(index for index, (name, _) in enumerate(calls) if name == 'curl')
        self.assertLess(key_download, calls.index(['dnf', ['install', '--assumeyes', 'mise']]))
        self.assertFalse(any(name in ('git', 'mise') for name, _ in calls))
        self.assertEqual(list(self.home.iterdir()), [])
        self.state = json.loads((self.root/'state.json').read_text())
        before = len(self.calls())
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse(any(name in ('sudo', 'dnf') for name, _ in self.calls()[before:]))

    def test_provision_retains_installed_mise(self):
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse((self.root/'system').exists())
        self.assertFalse(any('mise' in args or name in ('dnf', 'curl') for name, args in self.calls()))

    def test_mise_key_fingerprint_mismatch_fails_without_installing_mise(self):
        (self.bin/'mise').unlink()
        self.state['key_fingerprint'] = '0'*40
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fingerprint mismatch', result.stderr)
        self.assertNotIn('Prerequisites ready', result.stdout)
        self.assertFalse((self.bin/'mise').exists())
        self.assertFalse((self.root/'system').exists())
        self.assertFalse(any(name == 'dnf' for name, _ in self.calls()))

    def test_ubuntu_entry_points_are_gone(self):
        for name in ('provision-ubuntu.sh', 'bootstrap-ubuntu.sh'):
            self.assertFalse((REPO/name).exists(), name)

    def test_provision_rejects_uninspected_standalone_before_actions(self):
        shutil.rmtree(self.source/'scripts')
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inspected checkout', result.stderr)
        self.assertFalse(self.calls())

    def test_provision_failure_does_not_claim_success(self):
        self.state['fail'] = 'sudo'
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Prerequisites ready', result.stdout)

    def test_bootstrap_clones_only_to_empty_destination(self):
        if not self.chezmoi: self.skipTest('Real chezmoi required')
        destination = self.root/'permanent checkout'
        result = self.run_script('bootstrap-fedora.sh', destination)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue((destination/'.git').is_dir())
        self.assertIn(['git', ['clone', '--', 'https://github.com/hyperlapse122/dotfiles.git', str(destination)]], self.calls())
        self.assertFalse((self.home/'.fixture').exists())

    def test_nonempty_unrelated_directory_is_preserved(self):
        destination = self.root/'unrelated'; destination.mkdir()
        sentinel = destination/'keep'; sentinel.write_text('keep')
        result = self.run_script('bootstrap-fedora.sh', destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(destination.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertFalse(any(name in ('git', 'mise', 'sudo') for name, _ in self.calls()))

    def test_root_provisioning_rejected_before_package_actions(self):
        self.state['uid'] = '0'
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('normal user', result.stderr)
        self.assertFalse(any(name == 'sudo' for name, _ in self.calls()))

    def test_missing_python_blocks_before_package_actions(self):
        (self.bin/'python3').unlink()
        result = self.run_script('provision-fedora.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('python3', result.stderr)
        self.assertFalse(self.calls())

    def test_bootstrap_propagates_failed_preparation(self):
        for failed_action in (['install'], ['run', 'bootstrap']):
            with self.subTest(failed_action=failed_action):
                self.state['fail_mise'] = failed_action
                result = self.run_script('bootstrap-fedora.sh', self.source)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Prepared:', result.stdout)


if __name__ == '__main__':
    unittest.main()
