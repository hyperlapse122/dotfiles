import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_macos_bootstrap import MacFixture
from test_native_ca_shell import find_bash


class MacAria2Test(MacFixture):
    def test_formula_installs_once(self):
        for _ in range(2):
            result = self.run_script('scripts/macos-apps.sh', 'formula:aria2')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.state = json.loads((self.root / 'state.json').read_text())
        installs = [args for name, args in self.calls() if name == 'brew' and args[0] == 'install']
        self.assertEqual(installs, [['install', '--yes', '--formula', 'aria2']])


@unittest.skipUnless(shutil.which('chezmoi') and find_bash(), 'chezmoi and Bash required')
class LinuxAria2Test(unittest.TestCase):
    def test_platform_selection_and_idempotent_install(self):
        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            templates = root / '.chezmoitemplates'
            templates.mkdir()
            shutil.copy2(repo / 'home/.chezmoiscripts/run_before_17-install-aria2.sh.tmpl',
                         templates / 'aria2')
            config = root / 'empty.toml'
            config.write_text('')
            for os_name, distro, arch, version in [
                ('linux', 'ubuntu', arch, version)
                for arch in ('amd64', 'arm64') for version in ('24.04', '26.04')
            ] + [('linux', 'debian', 'amd64', '12'), ('linux', 'ubuntu', '386', '24.04'),
                 ('linux', 'ubuntu', 'amd64', '25.10'), ('darwin', '', 'arm64', ''),
                 ('windows', '', 'amd64', '')]:
                with self.subTest(os=os_name, distro=distro, arch=arch, version=version):
                    data = {'chezmoi': {'os': os_name, 'arch': arch,
                                        'osRelease': {'id': distro, 'versionID': version}, 'workingTree': str(repo)}}
                    template = '{{ $data := ' + json.dumps(json.dumps(data)) + ' | fromJson }}{{ includeTemplate "aria2" $data }}'
                    result = subprocess.run(['chezmoi', '--source', str(root), '--config', str(config),
                                             'execute-template', template], capture_output=True, text=True, check=True)
                    supported = (os_name == 'linux' and distro == 'ubuntu' and
                                 arch == 'amd64' and version == '26.04')
                    self.assertEqual(bool(result.stdout.strip()), supported)
                    if supported:
                        script = result.stdout
            commands = root / 'commands'
            commands.mkdir()
            calls = root / 'calls'
            python = commands / 'python3'
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ARIA2_TEST_PROBE"\nexit "${ARIA2_TEST_PROBE_EXIT:-0}"\n')
            python.chmod(0o755)
            sudo = commands / 'sudo'
            sudo.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$ARIA2_TEST_CALLS"\n')
            sudo.chmod(0o755)
            env = dict(os.environ, ARIA2_TEST_CALLS=calls.as_posix(), ARIA2_TEST_PROBE=str(root/'probe-calls'))
            command = 'PATH="$(cd "$1" && pwd -P)"; export PATH; shift; eval "$1"'
            blocked=subprocess.run([find_bash(), '--noprofile', '--norc', '-c', command,
                                    'fixture', commands.as_posix(), script],
                                   env=dict(env,ARIA2_TEST_PROBE_EXIT='1'),capture_output=True,text=True)
            self.assertNotEqual(blocked.returncode,0)
            self.assertFalse(calls.exists())
            for _ in range(2):
                result = subprocess.run([find_bash(), '--noprofile', '--norc', '-c', command,
                                         'fixture', commands.as_posix(), script], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                aria2c = commands / 'aria2c'
                aria2c.write_text('#!/bin/sh\nexit 0\n')
                aria2c.chmod(0o755)
            self.assertEqual(calls.read_text().splitlines(), ['apt-get install -y aria2'])
