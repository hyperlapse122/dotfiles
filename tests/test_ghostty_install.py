import hashlib
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
import json, os, pathlib, sys
name, *args = sys.argv[1:]
root = pathlib.Path(os.environ['GHOSTTY_TEST_ROOT'])
state = json.loads((root/'state.json').read_text())
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([name, args])+'\n')
if state.get('fail') == name: sys.exit(23)
if name == 'uname': print(state.get('os', 'Linux'))
elif name == 'dpkg': print(state.get('arch', 'amd64'))
elif name in ('ghostty', 'zsh'): sys.exit(0 if state.get(name, False) else 1)
elif name == 'curl':
    output = args[args.index('--output')+1]
    if os.name == 'nt' and len(output) > 3 and output[0] == '/' and output[2] == '/':
        output = output[1] + ':' + output[2:]
    pathlib.Path(output).write_bytes(b'fixture Debian package')
elif name == 'sudo':
    if args[:3] != ['apt-get', 'install', '-y']: sys.exit(41)
    for item in args[3:]:
        if item == 'zsh': state['zsh'] = True
        elif item == 'ghostty' or item.endswith('.deb'): state['ghostty'] = True
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
        self.state = {'zsh': True}
        self.fixture = self.root/'fixture.py'
        self.fixture.write_text(FIXTURE, encoding='utf-8')
        for name in ('uname', 'dpkg', 'ghostty', 'zsh', 'curl', 'sudo'):
            self.wrapper(name)
        utilities = ('bash', 'mktemp', 'rm', 'sha256sum', 'awk')
        resolved = subprocess.run([find_bash(), '--noprofile', '--norc', '-c',
                                   'PATH=/usr/bin:/bin; command -v ' + ' '.join(utilities)],
                                  capture_output=True, text=True, check=True)
        for name, executable in zip(utilities, resolved.stdout.splitlines(), strict=True):
            target = self.bin/name
            target.write_text('#!/bin/sh\nexec '+shlex.quote(executable)+' "$@"\n', encoding='utf-8')
            target.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home), TMPDIR=str(self.root),
                        GHOSTTY_TEST_ROOT=str(self.root), XDG_CONFIG_HOME=str(self.home/'.config'))

    def wrapper(self, name):
        path = self.bin/name
        path.write_text('#!/bin/sh\nexec '+shlex.quote(Path(sys.executable).as_posix())+' '+
                        shlex.quote(self.fixture.as_posix())+' '+shlex.quote(name)+' "$@"\n', encoding='utf-8')
        path.chmod(0o755)

    def run_install(self, release='24.04', arch='amd64', digest=None):
        (self.root/'state.json').write_text(json.dumps(self.state), encoding='utf-8')
        os_release = self.root/'os-release'
        os_release.write_text('ID=ubuntu\nVERSION_ID='+self.state.get('release', release)+'\n')
        script = self.root/'install.sh'
        text = (self.repo/'scripts/install-ghostty.sh').read_text(encoding='utf-8')
        text = text.replace("'/etc/os-release'", shlex.quote(os_release.as_posix()))
        for native_shell in ("'/bin/zsh'", "'/usr/bin/zsh'"):
            text = text.replace(native_shell, shlex.quote((self.bin/'zsh').as_posix()))
        script.write_text(text, encoding='utf-8')
        args = [release, arch, 'https://example.invalid/ghostty.deb',
                digest or hashlib.sha256(b'fixture Debian package').hexdigest()]
        command = 'PATH="$(cd "$1" && pwd -P)"; export PATH; shift; exec bash --noprofile --norc "$@"'
        result = subprocess.run([find_bash(), '--noprofile', '--norc', '-c', command, 'fixture',
                                 self.bin.as_posix(), script.as_posix(), *args], env=self.env,
                                capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.state = json.loads((self.root/'state.json').read_text())
        return result

    def calls(self):
        path = self.root/'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_verified_community_package_installs_and_reapply_is_offline(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.state['ghostty'])
        self.assertTrue(any(name == 'curl' for name, args in self.calls()))
        before = len(self.calls())
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(name in ('curl', 'sudo') for name, args in self.calls()[before:]))
        self.assertFalse(list(self.root.glob('dotfiles-ghostty.*')))

    def test_hash_mismatch_never_installs_unverified_package(self):
        result = self.run_install(digest='0'*64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SHA-256', result.stderr)
        self.assertFalse(any(name == 'sudo' for name, args in self.calls()))
        self.assertFalse(self.state.get('ghostty'))

    def test_26_archive_and_missing_shell_are_installed_without_download(self):
        self.state['zsh'] = False
        result = self.run_install('26.04')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.state['ghostty'])
        self.assertTrue(self.state['zsh'])
        self.assertFalse(any(name == 'curl' for name, args in self.calls()))
        self.assertIn(['sudo', ['apt-get', 'install', '-y', 'ghostty']], self.calls())

    def test_unsupported_or_mismatched_host_stops_before_install(self):
        for changes, release, arch in [({'os': 'Darwin'}, '24.04', 'amd64'),
                                       ({}, '25.10', 'amd64'), ({}, '24.04', '386'),
                                       ({'arch': 'arm64'}, '24.04', 'amd64'),
                                       ({'release': '26.04'}, '24.04', 'amd64')]:
            with self.subTest(changes=changes, release=release, arch=arch):
                self.state = {'zsh': True, **changes}
                before = len(self.calls())
                result = self.run_install(release, arch)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(name in ('sudo', 'curl') for name, args in self.calls()[before:]))

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_hook_only_renders_supported_ubuntu_platforms(self):
        source = self.root/'source'
        templates = source/'.chezmoitemplates'
        templates.mkdir(parents=True)
        shutil.copy2(self.repo/'home/.chezmoiscripts/run_before_16-install-ghostty.sh.tmpl', templates/'install-hook')
        config = self.root/'empty.toml'
        config.write_text('')
        for os_name, arch, release in [('linux', 'amd64', '24.04'), ('linux', 'arm64', '26.04'),
                                        ('linux', '386', '24.04'), ('linux', 'amd64', '25.10'),
                                        ('windows', 'amd64', ''), ('darwin', 'arm64', '')]:
            with self.subTest(os=os_name, arch=arch, release=release):
                data = {'chezmoi': {'os': os_name, 'arch': arch, 'workingTree': str(self.repo),
                                    'osRelease': {'id': 'ubuntu', 'versionID': release}},
                        'ghostty': {'ubuntu2404': {arch: {'url': 'https://example.invalid/a.deb', 'sha256': 'a'*64}}}}
                template = '{{ $data := '+json.dumps(json.dumps(data))+' | fromJson }}{{ includeTemplate "install-hook" $data }}'
                result = subprocess.run(['chezmoi', '--source', str(source), '--config', str(config),
                                          'execute-template', template], env=self.env, capture_output=True,
                                         text=True, encoding='utf-8', timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                supported = os_name == 'linux' and arch in ('amd64', 'arm64') and release in ('24.04', '26.04')
                self.assertEqual(bool(result.stdout.strip()), supported)
                if supported:
                    syntax = subprocess.run([find_bash(), '-n'], input=result.stdout, capture_output=True, text=True)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
