import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SPEC = REPO / 'crates/pinentry/dotfiles-pinentry.usage.kdl'
USAGE = shutil.which('usage')
POWERSHELL = shutil.which('pwsh')


def powershell_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def bash_command():
    if os.name == 'nt':
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe'
        return str(candidate) if candidate.exists() else None
    return shutil.which('bash')


def bash_library():
    candidates = [os.environ.get('DOTFILES_BASH_COMPLETION_FIXTURE'),
                  '/usr/share/bash-completion/bash_completion',
                  '/opt/homebrew/etc/profile.d/bash_completion.sh']
    return next((Path(p) for p in candidates if p and Path(p).is_file()), None)


def bash_path(path):
    value = Path(path).as_posix()
    return '/' + value[0].lower() + value[2:] if os.name == 'nt' and Path(path).drive else value


@unittest.skipUnless(USAGE, 'mise-managed Usage required')
class CompletionContractTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('cli_completions', REPO / 'scripts/cli-completions.py')
        self.generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.generator)
        temporary = tempfile.TemporaryDirectory(prefix="CLI completion 한글 owner's ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "user's home"
        self.binary = self.home / '.local/bin' / ('dotfiles-pinentry.exe' if os.name == 'nt' else 'dotfiles-pinentry')
        self.binary.parent.mkdir(parents=True)
        # The spec producer is a boundary fixture; Rust CLI tests prove the real
        # binary's early --usage-spec branch. Completion must never run this file.
        shutil.copy2(sys.executable, self.binary)
        self.usage = self.root / "tool's directory" / ('usage.exe' if os.name == 'nt' else 'usage')
        self.usage.parent.mkdir()
        shutil.copy2(USAGE, self.usage)
        self.output = self.home / '.local/share/dotfiles/completions'
        self.real_run = subprocess.run

    def generate(self):
        def command(argv, **kwargs):
            if argv == [str(self.binary), '--usage-spec']:
                return subprocess.CompletedProcess(argv, 0, SPEC.read_text(encoding='utf-8'), '')
            return self.real_run(argv, **kwargs)
        with mock.patch.object(self.generator.subprocess, 'run', side_effect=command):
            self.generator.generate(self.home, self.usage)

    def test_spec_lints_and_completes_only_public_surface(self):
        result = self.real_run([USAGE, 'lint', str(SPEC)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for words, expected in ((['dotfiles-pinentry', 'f'], 'forget'),
                                (['dotfiles-pinentry', '--v'], '--version'),
                                (['dotfiles-pinentry', '--usage'], '--usage-spec')):
            result = self.real_run([USAGE, 'complete-word', '--shell', 'bash', '-f', str(SPEC), '--', *words],
                                   capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, [line.split('\t')[0] for line in result.stdout.splitlines()])
        result = self.real_run([USAGE, 'complete-word', '-f', str(SPEC), '--', 'dotfiles-pinentry', 'forget', '123'],
                               capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_generation_is_idempotent_and_failed_spec_preserves_outputs(self):
        self.generate()
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()}
        self.generate()
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()})
        with mock.patch.object(self.generator.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')):
            with self.assertRaises(subprocess.CalledProcessError):
                self.generator.generate(self.home, self.usage)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()})

    @unittest.skipUnless(POWERSHELL, 'PowerShell required')
    def test_fresh_powershell_session_resolves_native_completions_without_pinentry(self):
        self.generate()
        profile = self.output / 'dotfiles-pinentry.ps1'
        if shutil.which('chezmoi') and shutil.which('mise'):
            config = self.root / 'chezmoi.toml'
            config.write_text('')
            rendered = self.real_run(['chezmoi', '--source', str(REPO), '--destination', str(self.home),
                                      '--config', str(config), 'execute-template',
                                      '{{ includeTemplate "powershell-mise-profile" . }}'],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            profile = self.root / 'profile.ps1'
            profile.write_text(rendered.stdout, encoding='utf-8-sig')
        script = ("$ErrorActionPreference = 'Stop'; . " + powershell_quote(profile) + '; '
                  "$line = 'dotfiles-pinentry --v'; "
                  '$matches = [System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null); '
                  '@($matches.CompletionMatches | ForEach-Object { $_.CompletionText }) | ConvertTo-Json -Compress')
        environment = os.environ.copy()
        environment.update(HOME=str(self.home), USERPROFILE=str(self.home),
                           APPDATA=str(self.root / 'appdata'), LOCALAPPDATA=str(self.root / 'local'))
        environment['PATH'] = str(self.binary.parent) + os.pathsep + environment['PATH']
        environment['GNUPGHOME'] = str(self.root / 'no-gpg-or-card-state')
        result = self.real_run([POWERSHELL, '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                               capture_output=True, text=True, encoding='utf-8', env=environment, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        matches = json.loads(result.stdout)
        self.assertIn('--version', [matches] if isinstance(matches, str) else matches)

    @unittest.skipUnless(os.name != 'nt' and bash_command() and bash_library(),
                         'Managed Unix Bash >=4.2 and bash-completion fixture required')
    def test_fresh_bash_session_resolves_registered_command(self):
        self.generate()
        script = ('source "$1"; source "$2"; '
                  'COMP_WORDS=(dotfiles-pinentry f); COMP_CWORD=1; '
                  'COMP_LINE="dotfiles-pinentry f"; COMP_POINT=${#COMP_LINE}; '
                  '_dotfiles_pinentry; printf "%s\\n" "${COMPREPLY[@]}"')
        environment = os.environ.copy()
        environment.update(HOME=bash_path(self.home), BASH_COMPLETION_USER_FILE=bash_path(self.root / 'absent'),
                           BASH_COMPLETION_COMPAT_DIR=bash_path(self.root / 'absent'))
        result = self.real_run([bash_command(), '--noprofile', '--norc', '-i', '-c', script, 'fixture',
                               bash_path(bash_library()), bash_path(self.output / 'dotfiles-pinentry.bash')],
                               capture_output=True, text=True, env=environment, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('forget', result.stdout.splitlines())

    @unittest.skipUnless(shutil.which('zsh'), 'Managed Unix Zsh required')
    def test_fresh_zsh_session_registers_generated_completion(self):
        self.generate()
        environment = os.environ.copy()
        environment.update(HOME=str(self.home), ZDOTDIR=str(self.home))
        command = ('autoload -Uz compinit; compinit -D; source "$1"; '
                   'print -r -- "${_comps[dotfiles-pinentry]}"')
        result = self.real_run([shutil.which('zsh'), '-f', '-i', '-c', command, 'fixture',
                               str(self.output / 'dotfiles-pinentry.zsh')],
                              capture_output=True, text=True, env=environment, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('_dotfiles_pinentry', result.stdout.splitlines())


class CompletionProfileTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_owned_shell_blocks_preserve_sentinels_and_reject_broken_markers(self):
        with tempfile.TemporaryDirectory(prefix='completion-profile-') as temporary:
            root = Path(temporary)
            config = root / 'chezmoi.toml'
            config.write_text('')
            for shell in ('bash', 'zsh'):
                expression = '{{ includeTemplate "cli-completions-shell" (merge (dict "shell" "' + shell + '") .) }}'
                def render(content):
                    return subprocess.run(['chezmoi', '--source', str(REPO), '--config', str(config),
                                           'execute-template', '--with-stdin', expression],
                                          input=content, capture_output=True, text=True, timeout=30)
                first = render('# unrelated sentinel\n')
                self.assertEqual(first.returncode, 0, first.stderr)
                second = render(first.stdout)
                self.assertEqual(second.returncode, 0, second.stderr)
                self.assertEqual(first.stdout, second.stdout)
                self.assertIn('# unrelated sentinel', second.stdout)
                broken = render('# >>> dotfiles CLI completions >>>\n')
                self.assertNotEqual(broken.returncode, 0)

    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_bash_modifier_composes_native_ca_and_completion_blocks(self):
        with tempfile.TemporaryDirectory(prefix='completion-bashrc-') as temporary:
            config = Path(temporary) / 'chezmoi.toml'
            config.write_text('')
            expression = (REPO / 'home/modify_dot_bashrc').read_text(encoding='utf-8')
            command = ['chezmoi', '--source', str(REPO), '--config', str(config),
                       'execute-template', '--with-stdin', expression]
            first = subprocess.run(command, input='# user sentinel\n', capture_output=True, text=True, timeout=30)
            self.assertEqual(first.returncode, 0, first.stderr)
            second = subprocess.run(command, input=first.stdout, capture_output=True, text=True, timeout=30)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(first.stdout, second.stdout)
            self.assertEqual(first.stdout.count('# >>> dotfiles CLI completions >>>'), 1)
            self.assertEqual(first.stdout.count('# >>> dotfiles native system CA >>>'), 1)
            self.assertIn('# user sentinel', first.stdout)

    @unittest.skipUnless(shutil.which('chezmoi'), 'chezmoi required')
    def test_locked_bash_assets_include_required_compatibility_and_license(self):
        with tempfile.TemporaryDirectory(prefix='completion-assets-') as temporary:
            config = Path(temporary) / 'chezmoi.toml'
            config.write_text('')
            template = (REPO / 'home/.chezmoiexternals/cli-completions.toml.tmpl').read_text(encoding='utf-8')
            wrapper = ('{{ template "assets" (dict "chezmoi" (dict "os" "linux") '
                       '"cliCompletionAssets" .cliCompletionAssets) }}{{ define "assets" }}' + template + '{{ end }}')
            rendered = subprocess.run(['chezmoi', '--source', str(REPO), '--config', str(config), 'execute-template'],
                                      input=wrapper, capture_output=True, text=True, timeout=30)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            import tomllib
            assets = tomllib.loads(rendered.stdout)
            self.assertEqual(len(assets), 3)
            self.assertTrue(any('startup-core' in name for name in assets))
            self.assertTrue(any(name.endswith('/COPYING') for name in assets))
            for item in assets.values():
                self.assertEqual(item['checksum']['sha256'], '88bcf85124f77f74f2f2f8bcd16ac4382d807a827ede742a64940c7116aea33f')


if __name__ == '__main__':
    unittest.main()
