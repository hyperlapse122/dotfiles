import json
import shlex
import shutil
import subprocess
import unittest

from test_macos_bootstrap import FIXTURE, MacFixture
from test_native_ca_shell import find_bash


PREREQUISITES = ("git", "mise", "chezmoi", "gnupg", "pinentry-mac")
PROVISION_HANDLERS = r"""
if name == 'id':
    print(state.get('uid', '501')); sys.exit()
if name == 'curl':
    if state.get('fail') == 'curl': sys.exit(23)
    import shutil
    shutil.copy2(root/'installer-template', args[args.index('--output')+1])
    sys.exit()
if name == 'install-homebrew':
    if state.get('fail') == 'install-homebrew': sys.exit(23)
    import shutil
    target = root/'homebrew prefix/bin/brew'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root/'brew-template', target)
    sys.exit()
if name == 'brew':
    if state.get('fail') == 'brew': sys.exit(23)
    prefix = root/'homebrew prefix'
    if args == ['--prefix']:
        print(state.get('brew_prefix', prefix.as_posix()))
    elif args == ['shellenv']:
        import shlex
        print('export PATH="$(cd ' + shlex.quote((prefix/'bin').as_posix()) + ' && pwd -P):$PATH"')
    elif args[:1] == ['--prefix']:
        print((root/'tools'/args[1]).as_posix())
    elif args[:1] == ['list']:
        sys.exit(0 if args[-1] in state.get('packages', []) else 1)
    elif args[:1] == ['install']:
        package = args[-1]
        if state.get('fail_package') == package: sys.exit(23)
        state.setdefault('packages', []).append(package)
        executables = {'gnupg': ['gpg', 'gpgconf'], 'pinentry-mac': ['pinentry-mac']}.get(package, [package])
        for executable in executables:
            if executable == state.get('missing_executable'): continue
            target = root/'tools'/package/'bin'/executable
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('#!/bin/sh\nexit 0\n'); target.chmod(0o755)
            public = prefix/'bin'/executable
            public.parent.mkdir(parents=True, exist_ok=True)
            public.write_bytes(target.read_bytes()); public.chmod(0o755)
        (root/'state.json').write_text(json.dumps(state))
    else:
        sys.exit('Unexpected brew arguments: ' + repr(args))
    sys.exit()
"""


class MacProvisionTest(MacFixture):
    def setUp(self):
        super().setUp()
        self.fixture.write_text(FIXTURE.replace("if state.get('fail') == name:", PROVISION_HANDLERS + "\nif state.get('fail') == name:"), encoding='utf-8')
        for command in ('brew', 'git', 'mise'):
            (self.bin/command).unlink()
        for command in ('id', 'curl'):
            self.wrapper(self.bin/command, command)
        self.wrapper(self.root/'brew-template', 'brew')
        self.wrapper(self.root/'installer-template', 'install-homebrew')
        # No fixture package is installed until its fake brew install runs.
        shutil.rmtree(self.root/'tools')
        self.env['TMPDIR'] = str(self.root/'temporary files')
        (self.root/'temporary files').mkdir()
        self.env['PYTHONDONTWRITEBYTECODE'] = '1'
        resolved = subprocess.run(
            [find_bash(), '--noprofile', '--norc', '-c',
             'PATH=/usr/bin:/bin; export PATH; command -v mktemp rm'],
            capture_output=True, text=True, encoding='utf-8', check=True)
        for command, executable in zip(('mktemp', 'rm'), resolved.stdout.splitlines(), strict=True):
            target = self.bin/command
            target.write_text('#!/bin/sh\nexec ' + shlex.quote(executable) + ' "$@"\n', encoding='utf-8')
            target.chmod(0o755)

    def native_brew(self):
        target = self.root/'homebrew prefix/bin/brew'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.root/'brew-template', target)

    def run_provision(self):
        # Absolute native Homebrew and Bash locations are confined to the test copy.
        script = self.root/'provision copy.sh'
        text = (self.repo/'provision-macos.sh').read_text(encoding='utf-8')
        text = text.replace('/opt/homebrew', (self.root/'homebrew prefix').as_posix())
        text = text.replace('/bin/bash', 'bash')
        script.write_text(text, encoding='utf-8')
        return self.run_script(script)

    def installed(self):
        return [args[-1] for name, args in self.calls() if name == 'brew' and args[:1] == ['install']]

    def test_first_device_installs_homebrew_and_missing_prerequisites_only(self):
        result = self.run_provision()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.installed(), list(PREREQUISITES))
        self.assertIn(['install-homebrew', []], self.calls())
        downloads = [args for name, args in self.calls() if name == 'curl']
        self.assertEqual(len(downloads), 1)
        self.assertIn('https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh', downloads[0])
        self.assertFalse(list((self.root/'temporary files').iterdir()))
        self.assertFalse(any(name in ('git', 'mise', 'chezmoi') for name, args in self.calls()))
        self.assertEqual(list(self.home.iterdir()), [])

    def test_repeat_run_neither_downloads_nor_installs_or_upgrades(self):
        first = self.run_provision()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.state = json.loads((self.root/'state.json').read_text())
        before = len(self.calls())
        result = self.run_provision()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        repeated = self.calls()[before:]
        self.assertFalse(any(name in ('curl', 'install-homebrew') for name, args in repeated))
        self.assertFalse(any(name == 'brew' and args[0] in ('install', 'upgrade') for name, args in repeated))

    def test_partial_failure_is_retryable_without_reinstalling_completed_packages(self):
        self.state['fail_package'] = 'chezmoi'
        first = self.run_provision()
        self.assertNotEqual(first.returncode, 0)
        self.state = json.loads((self.root/'state.json').read_text())
        self.assertEqual(self.state['packages'], ['git', 'mise'])
        del self.state['fail_package']
        before = len(self.calls())
        result = self.run_provision()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        repeated = self.calls()[before:]
        self.assertEqual([args[-1] for name, args in repeated if name == 'brew' and args[0] == 'install'],
                         ['chezmoi', 'gnupg', 'pinentry-mac'])
        self.assertFalse(any(name == 'install-homebrew' for name, args in repeated))

    def test_unlinked_mise_does_not_claim_prerequisites_are_ready(self):
        first = self.run_provision()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.state = json.loads((self.root/'state.json').read_text())
        (self.root/'homebrew prefix/bin/mise').unlink()
        self.assertTrue((self.root/'tools/mise/bin/mise').is_file())
        before = len(self.calls())
        result = self.run_provision()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('brew link mise', result.stderr)
        self.assertNotIn('Prerequisites ready', result.stdout)
        self.assertFalse(any(name == 'brew' and args[0] in ('install', 'upgrade', 'link')
                             for name, args in self.calls()[before:]))

    def test_host_and_compiler_guards_precede_provisioning(self):
        for override, diagnostic in [({'os': 'Linux'}, 'macOS'), ({'arch': 'x86_64'}, 'Apple Silicon'),
                                     ({'version': '14.7'}, 'macOS 15'), ({'translated': '1'}, 'Rosetta'),
                                     ({'uid': '0'}, 'normal user'), ({'fail': 'xcode-select'}, 'xcode-select --install'),
                                     ({'fail': 'xcrun'}, 'compiler')]:
            with self.subTest(override=override):
                self.state = {'source': str(self.source), **override}
                result = self.run_provision()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertFalse(any(name in ('curl', 'brew', 'install-homebrew') for name, args in self.calls()))

    def test_incompatible_homebrew_prefix_stops_before_installing(self):
        self.state['brew_prefix'] = '/usr/local'
        for location in ('PATH', 'native'):
            with self.subTest(location=location):
                if location == 'PATH':
                    self.wrapper(self.bin/'brew', 'brew')
                else:
                    (self.bin/'brew').unlink()
                    self.native_brew()
                result = self.run_provision()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Homebrew', result.stderr)
                self.assertFalse(self.installed())
                self.assertFalse(any(name == 'curl' for name, args in self.calls()))

    def test_download_and_installer_failures_clean_up_without_package_installation(self):
        for failure in ('curl', 'install-homebrew'):
            with self.subTest(failure=failure):
                self.state['fail'] = failure
                result = self.run_provision()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.installed())
                self.assertFalse(list((self.root/'temporary files').iterdir()))
                self.assertNotIn('Prerequisites ready', result.stdout)

    def test_missing_final_executable_does_not_claim_success(self):
        self.state['missing_executable'] = 'gpgconf'
        result = self.run_provision()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('gpgconf', result.stderr)
        self.assertNotIn('Prerequisites ready', result.stdout)


if __name__ == '__main__':
    unittest.main()
