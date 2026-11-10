import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_native_ca_shell import find_bash


FIXTURE = r'''
import json, os, pathlib, shlex, subprocess, sys
name, *args = sys.argv[1:]
root = pathlib.Path(os.environ['GHOSTTY_TEST_ROOT'])
state = json.loads((root/'state.json').read_text())
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if name == 'rpm': print(state.get('arch', 'x86_64'))
elif name in ('ghostty', 'zsh'): sys.exit(0 if state.get(name, False) else 1)
elif name == 'python3':
    import importlib.util
    spec=importlib.util.spec_from_file_location('probe',os.environ['HOST_PROBE'])
    probe=importlib.util.module_from_spec(spec);spec.loader.exec_module(probe)
    def run_probe(args, **kwargs):
        command = shlex.join(['bash', (root/'commands'/args[0]).as_posix(), *args[1:]])
        return subprocess.run([os.environ['FIXTURE_BASH'], '--noprofile', '--norc', '-c', command], **kwargs)
    report=probe.inspect_host(system=state.get('os','Linux'),
        os_release={'ID':state.get('distro','fedora'),'VERSION_ID':state.get('release','45'),
                    'VARIANT_ID':state.get('variant','kde')},
        run=run_probe, ostree_booted=False)
    print(json.dumps(report));sys.exit(0 if report['supported'] else 1)
elif name == 'sudo':
    if args[:3] != ['dnf', 'install', '-y']: sys.exit(41)
    for item in args[3:]:
        if item == 'zsh': state['zsh'] = True
    (root/'state.json').write_text(json.dumps(state))
'''


@unittest.skipUnless(find_bash(), 'Native Bash or Git Bash required')
class GhosttyInstallTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="ghostty install 한글 '")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.bin = self.root/'commands'
        self.bin.mkdir()
        self.home = self.root/'home'
        self.home.mkdir()
        self.state = {'zsh': True, 'ghostty': True}
        self.fixture = self.root/'fixture.py'
        self.fixture.write_text(FIXTURE, encoding='utf-8')
        for name in ('rpm', 'ghostty', 'zsh', 'sudo', 'python3'):
            self.wrapper(name)
        utilities = ('bash', 'mktemp', 'rm', 'awk', 'dirname')
        resolved = subprocess.run([find_bash(), '--noprofile', '--norc', '-c',
                                   'PATH=/usr/bin:/bin; command -v ' + ' '.join(utilities)],
                                  capture_output=True, text=True, check=True)
        for name, executable in zip(utilities, resolved.stdout.splitlines(), strict=True):
            target = self.bin/name
            target.write_text('#!/bin/sh\nexec '+shlex.quote(executable)+' "$@"\n', encoding='utf-8')
            target.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home), TMPDIR=str(self.root),
                        GHOSTTY_TEST_ROOT=str(self.root), FIXTURE_BASH=find_bash(),
                        HOST_PROBE=str(self.repo/'scripts/linux-platform.py'),
                        XDG_CONFIG_HOME=str(self.home/'.config'))

    def wrapper(self, name):
        path = self.bin/name
        path.write_text('#!/bin/sh\nexec '+shlex.quote(Path(sys.executable).as_posix())+' '+
                        shlex.quote(self.fixture.as_posix())+' '+shlex.quote(name)+' "$@"\n', encoding='utf-8')
        path.chmod(0o755)

    def run_install(self):
        (self.root/'state.json').write_text(json.dumps(self.state), encoding='utf-8')
        os_release = self.root/'os-release'
        os_release.write_text('ID=fedora\nVERSION_ID='+self.state.get('release', '45')+'\n')
        script = self.root/'install.sh'
        text = (self.repo/'scripts/install-ghostty.sh').read_text(encoding='utf-8')
        text = text.replace("'/etc/os-release'", shlex.quote(os_release.as_posix()))
        for native_shell in ("'/bin/zsh'", "'/usr/bin/zsh'"):
            text = text.replace(native_shell, shlex.quote((self.bin/'zsh').as_posix()))
        script.write_text(text, encoding='utf-8')
        command = 'PATH="$(cd "$1" && pwd -P)"; export PATH; shift; exec bash --noprofile --norc "$@"'
        result = subprocess.run([find_bash(), '--noprofile', '--norc', '-c', command, 'fixture',
                                 self.bin.as_posix(), script.as_posix()], env=self.env,
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.state = json.loads((self.root/'state.json').read_text())
        return result

    def calls(self):
        path = self.root/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_present_ghostty_and_zsh_run_no_install(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(name == 'sudo' for name, args in self.calls()))

    def test_missing_zsh_is_installed_with_dnf(self):
        self.state['zsh'] = False
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.state['zsh'])
        self.assertEqual([call for call in self.calls() if call[0] == 'sudo'],
                         [['sudo', ['dnf', 'install', '-y', 'zsh']]])

    def test_missing_ghostty_points_at_the_declared_repository(self):
        for release in ('45', '46'):
            with self.subTest(release=release):
                self.state = {'zsh': True, 'ghostty': False, 'release': release}
                before = len(self.calls())
                result = self.run_install()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('ghostty repository declared in', result.stderr)
                self.assertIn('home/.chezmoidata/linux.yaml', result.stderr)
                self.assertFalse(any(name == 'sudo' for name, args in self.calls()[before:]))

    def test_unsupported_host_stops_before_any_install(self):
        for changes in ({'os': 'Darwin'}, {'distro': 'ubuntu', 'release': '26.04'}, {'arch': 'aarch64'},
                        {'release': '44'}, {'variant': 'silverblue'}):
            with self.subTest(changes=changes):
                self.state = {'zsh': False, 'ghostty': False, **changes}
                before = len(self.calls())
                result = self.run_install()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(name in ('sudo', 'zsh', 'ghostty') for name, args in self.calls()[before:]))

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_hook_only_renders_for_amd64_fedora(self):
        source = self.root/'source'
        templates = source/'.chezmoitemplates'
        templates.mkdir(parents=True)
        shutil.copy2(self.repo/'home/.chezmoiscripts/run_before_16-install-ghostty.sh.tmpl', templates/'install-hook')
        config = self.root/'empty.toml'
        config.write_text('')
        for os_name, distro, arch, release in [('linux', 'fedora', 'amd64', '45'), ('linux', 'fedora', 'amd64', '46'),
                                               ('linux', 'fedora', 'arm64', '45'), ('linux', 'fedora', '386', '45'),
                                               ('linux', 'ubuntu', 'amd64', '26.04'), ('linux', 'ubuntu', 'arm64', '26.04'),
                                               ('windows', '', 'amd64', ''), ('darwin', '', 'arm64', '')]:
            with self.subTest(os=os_name, distro=distro, arch=arch, release=release):
                data = {'chezmoi': {'os': os_name, 'arch': arch, 'workingTree': str(self.repo),
                                    'osRelease': {'id': distro, 'versionID': release}}}
                template = '{{ $data := '+json.dumps(json.dumps(data))+' | fromJson }}{{ includeTemplate "install-hook" $data }}'
                result = subprocess.run(['chezmoi', '--source', str(source), '--config', str(config),
                                          'execute-template', template], env=self.env, capture_output=True,
                                         text=True, encoding='utf-8', timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                supported = (os_name, distro, arch) == ('linux', 'fedora', 'amd64')
                self.assertEqual(bool(result.stdout.strip()), supported)
                if supported:
                    self.assertIn('# file install-ghostty sha256: ', result.stdout)
                    exec_line = next(line for line in result.stdout.splitlines() if line.startswith('exec '))
                    self.assertTrue(exec_line.endswith("install-ghostty.sh'"), exec_line)
                    syntax = subprocess.run([find_bash(), '-n'], input=result.stdout, capture_output=True, text=True)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
