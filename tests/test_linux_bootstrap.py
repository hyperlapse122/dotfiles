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
import importlib.util, json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['LINUX_TEST_ROOT'])
state = json.loads((root/'state.json').read_text())
name, *args = sys.argv[1:]
with (root/'calls.jsonl').open('a') as stream: stream.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if name == 'mise' and args == state.get('fail_mise'): sys.exit(23)
if name == 'python3':
    spec = importlib.util.spec_from_file_location('linux_platform', args[0])
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    def run(command, **kwargs):
        output = state.get('arch', 'amd64') if command[0] == 'dpkg' else ('install ok installed' if state.get('studio', True) else '')
        return subprocess.CompletedProcess(command, 0, output, '')
    report = module.inspect_host(system=state.get('os', 'Linux'), os_release={'ID': 'ubuntu', 'VERSION_ID': state.get('version', '26.04')}, environ={}, run=run)
    print(json.dumps(report)); sys.exit(0 if report['supported'] else 1)
elif name == 'git':
    if args[0] == 'clone': shutil.copytree(root/'source with spaces', args[-1], dirs_exist_ok=True)
    elif args[-2:] == ['--get', 'remote.origin.url']: print(state.get('origin', 'https://github.com/hyperlapse122/dotfiles.git'))
    elif args[-1] == '--show-prefix': print(state.get('prefix', ''))
elif name == 'id': print(state.get('uid', '1000'))
elif name == 'dpkg-query':
    print('install ok installed' if args[-1] in state.get('packages', []) else '')
elif name == 'sudo':
    # Never execute privileged commands; model successful package installation only.
    if args[:3] == ['apt-get', 'install', '-y']:
        state.setdefault('packages', []).extend(args[3:])
        if 'mise' in args[3:]: shutil.copy2(root/'mise-template', root/'bin/mise')
    (root/'state.json').write_text(json.dumps(state))
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
                     'bootstrap-ubuntu-studio.sh', 'provision-ubuntu-studio.sh', 'scripts/linux-platform.py'):
            target = self.source/name; target.parent.mkdir(parents=True, exist_ok=True)
            if (REPO/name).exists(): shutil.copy2(REPO/name, target)
        (self.source/'.git').mkdir()
        (self.source/'home').mkdir()
        (self.source/'home/dot_fixture').write_text('managed')
        self.fixture = self.root/'fixture.py'; self.fixture.write_text(FIXTURE)
        for name in ('git', 'python3', 'mise', 'id', 'dpkg-query', 'sudo', 'apt-get', 'extrepo', 'curl'):
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
            result = self.run_script('bootstrap-ubuntu-studio.sh', self.source)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse((self.home/'.fixture').exists())
            self.assertEqual(config.read_text(), text)
            self.assertEqual(sentinel.read_text(), 'keep')
        self.assertFalse(any(name in ('sudo', 'apt-get') for name, _ in self.calls()))
        self.assertEqual([args for name, args in self.calls() if name == 'mise'],
                         [['trust', str(self.source/'mise.toml')], ['install'], ['run', 'bootstrap']]*2)

    def test_unsupported_home_unchanged_for_both_entry_points(self):
        sentinel = self.home/'existing'; sentinel.write_bytes(b'keep')
        self.state['studio'] = False
        for name in ('bootstrap-ubuntu-studio.sh', 'provision-ubuntu-studio.sh'):
            result = self.run_script(name, self.source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('ubuntustudio', result.stdout+result.stderr)
        self.assertEqual(list(self.home.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b'keep')
        self.assertFalse(any(name in ('sudo', 'mise', 'git') for name, _ in self.calls()))

    def test_destination_guards_precede_preparation(self):
        for override in ({'origin': 'https://example.com/other.git'}, {'prefix': 'subdir/'}, {}):
            with self.subTest(override=override):
                self.state.update(override)
                if not override: (self.source/'.git').rmdir()
                result = self.run_script('bootstrap-ubuntu-studio.sh', self.source)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(name == 'mise' for name, _ in self.calls()))
                self.state.pop('origin', None); self.state.pop('prefix', None)

    def test_provision_only_installs_missing_prerequisites(self):
        (self.bin/'mise').unlink()
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        installs = [args for name, args in self.calls() if name == 'sudo']
        self.assertIn(['extrepo', 'enable', 'mise'], installs)
        self.assertIn(['apt-get', 'install', '-y', 'mise'], installs)
        self.assertFalse(any(name in ('git', 'mise') for name, _ in self.calls()))
        self.assertEqual(list(self.home.iterdir()), [])
        self.state = json.loads((self.root/'state.json').read_text())
        before = len(self.calls())
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertFalse(any(name == 'sudo' for name, _ in self.calls()[before:]))

    def test_provision_rejects_uninspected_standalone_before_actions(self):
        shutil.rmtree(self.source/'scripts')
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('inspected checkout', result.stderr)
        self.assertFalse(self.calls())

    def test_provision_failure_does_not_claim_success(self):
        self.state['fail'] = 'sudo'
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Prerequisites ready', result.stdout)

    def test_bootstrap_clones_only_to_empty_destination(self):
        if not self.chezmoi: self.skipTest('Real chezmoi required')
        destination = self.root/'permanent checkout'
        result = self.run_script('bootstrap-ubuntu-studio.sh', destination)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue((destination/'.git').is_dir())
        self.assertIn(['git', ['clone', '--', 'https://github.com/hyperlapse122/dotfiles.git', str(destination)]], self.calls())
        self.assertFalse((self.home/'.fixture').exists())

    def test_nonempty_unrelated_directory_is_preserved(self):
        destination = self.root/'unrelated'; destination.mkdir()
        sentinel = destination/'keep'; sentinel.write_text('keep')
        result = self.run_script('bootstrap-ubuntu-studio.sh', destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(destination.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), 'keep')
        self.assertFalse(any(name in ('git', 'mise', 'sudo') for name, _ in self.calls()))

    def test_root_provisioning_rejected_before_package_actions(self):
        self.state['uid'] = '0'
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('normal user', result.stderr)
        self.assertFalse(any(name == 'sudo' for name, _ in self.calls()))

    def test_missing_python_blocks_before_package_actions(self):
        (self.bin/'python3').unlink()
        result = self.run_script('provision-ubuntu-studio.sh', self.source)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('python3', result.stderr)
        self.assertFalse(self.calls())

    def test_bootstrap_propagates_failed_preparation(self):
        for failed_action in (['install'], ['run', 'bootstrap']):
            with self.subTest(failed_action=failed_action):
                self.state['fail_mise'] = failed_action
                result = self.run_script('bootstrap-ubuntu-studio.sh', self.source)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('Prepared:', result.stdout)


if __name__ == '__main__':
    unittest.main()
