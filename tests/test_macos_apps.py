import json
import os
import shutil
import subprocess
import unittest

from test_macos_bootstrap import MacFixture
from test_native_ca_shell import find_bash


class MacAppsTest(MacFixture):
    def test_usable_manual_ghostty_bundle_is_reused(self):
        executable = self.home / 'Applications/Ghostty.app/Contents/MacOS/ghostty'
        executable.parent.mkdir(parents=True)
        executable.write_text('#!/bin/sh\nexit 0\n')
        executable.chmod(0o755)
        result = self.run_script('scripts/macos-apps.sh', 'cask:ghostty')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(name == 'brew' and args[0] == 'install' for name, args in self.calls()))

    def test_incomplete_ghostty_bundle_does_not_count_as_installed(self):
        (self.home / 'Applications/Ghostty.app').mkdir(parents=True)
        result = self.run_script('scripts/macos-apps.sh', 'cask:ghostty')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(['brew', ['install', '--cask', 'ghostty']], self.calls())

    def test_unsupported_macos_stops_before_application_changes(self):
        self.state['version'] = '25.9'
        result = self.run_script('scripts/macos-apps.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('macOS 26', result.stderr)
        self.assertFalse(any(name in ('brew', 'podman') for name, args in self.calls()))

    def test_fresh_application_installs_once_without_podman(self):
        packages = ('cask:google-chrome', 'cask:1password', 'cask:1password-cli')
        result = self.run_script('scripts/macos-apps.sh', *packages)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        installs = [args for name, args in calls if name == 'brew' and args[0] == 'install']
        self.assertEqual(installs, [['install', '--cask', package.split(':')[1]] for package in packages])
        self.assertEqual(calls[-2:], [['brew', ['update']], ['brew', ['upgrade']]])
        self.assertFalse(any(name == 'podman' for name, args in calls))
        self.state = json.loads((self.root / 'state.json').read_text())
        before = len(calls)
        result = self.run_script('scripts/macos-apps.sh', *packages)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        repeated = self.calls()[before:]
        self.assertFalse(any(name == 'brew' and args[0] == 'install' for name, args in repeated))
        self.assertEqual(repeated[-2:], [['brew', ['update']], ['brew', ['upgrade']]])
        self.assertFalse(any(name == 'podman' for name, args in repeated))

    def test_existing_podman_and_stopped_machine_are_untouched(self):
        self.wrapper(self.bin / 'podman', 'podman')
        self.wrapper(self.root / 'bundled-podman', 'podman')
        self.state.update(packages=['podman'], machines='personal|false|true\n', fail='podman')
        result = self.run_script('scripts/macos-apps.sh', 'cask:google-chrome')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any(name == 'podman' or 'podman' in args for name, args in calls))
        after = json.loads((self.root / 'state.json').read_text())
        self.assertEqual(after['machines'], self.state['machines'])
        self.assertIn('podman', after['packages'])
        self.assertTrue((self.bin / 'podman').is_file())
        self.assertTrue((self.root / 'bundled-podman').is_file())

    def test_manual_app_bundles_and_cli_are_reused(self):
        (self.root / 'Applications/Google Chrome.app').mkdir(parents=True)
        (self.home / 'Applications/1Password.app').mkdir(parents=True)
        self.wrapper(self.bin / 'op', 'op')
        result = self.run_script('scripts/macos-apps.sh', 'cask:google-chrome', 'cask:1password', 'cask:1password-cli')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(name == 'brew' and args[0] == 'install' for name, args in self.calls()))

    def test_empty_app_list_still_updates_all_homebrew_packages(self):
        result = self.run_script('scripts/macos-apps.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls()[-2:], [['brew', ['update']], ['brew', ['upgrade']]])

    def test_update_failures_fail_application(self):
        for command in ('update', 'upgrade'):
            with self.subTest(command=command):
                self.state['fail'] = 'brew ' + command
                result = self.run_script('scripts/macos-apps.sh')
                self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
                self.assertEqual(self.calls()[-1], ['brew', [command]])
                if command == 'update':
                    self.assertNotIn(['brew', ['upgrade']], self.calls())

    @unittest.skipUnless(os.name != 'nt' and shutil.which('chezmoi'), 'Real POSIX chezmoi required')
    def test_unchanged_native_apply_updates_homebrew_each_time(self):
        templates = self.source / '.chezmoitemplates'
        templates.mkdir()
        hook = self.repo / 'home/.chezmoiscripts/run_before_15-install-macos-apps.sh.tmpl'
        shutil.copy2(hook, templates / 'app-hook')
        config = self.root / 'empty.toml'
        config.write_text('')
        data = {'chezmoi': {'os': 'darwin', 'arch': 'arm64', 'workingTree': str(self.repo)},
                'macos': {'formulae': [], 'casks': ['1password-cli']}}
        template = '{{ $data := ' + json.dumps(json.dumps(data)) + ' | fromJson }}{{ includeTemplate "app-hook" $data }}'
        chezmoi = shutil.which('chezmoi')
        rendered = subprocess.run([chezmoi, '--source', str(self.source), '--config', str(config),
                                   'execute-template', template],
                                  env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(rendered.returncode, 0, rendered.stdout + rendered.stderr)
        scripts = self.source / '.chezmoiscripts'
        scripts.mkdir()
        (scripts / hook.name.removesuffix('.tmpl')).write_text(rendered.stdout)
        (self.root / 'state.json').write_text(json.dumps(self.state))
        env = dict(self.env, PATH=str(self.bin))
        for _ in range(2):
            result = subprocess.run([chezmoi, '--source', str(self.source), '--destination', str(self.home),
                                     '--config', str(config), '--cache', str(self.root / 'cache'),
                                     '--persistent-state', str(self.root / 'chezmoi-state.boltdb'),
                                     '--no-tty', 'apply'],
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        mutations = [args for name, args in self.calls()
                     if name == 'brew' and args[0] in ('install', 'update', 'upgrade')]
        self.assertEqual(mutations, [['install', '--cask', '1password-cli'],
                                     ['update'], ['upgrade'], ['update'], ['upgrade']])

    def test_command_failure_stops_application(self):
        self.state['fail'] = 'brew'
        result = self.run_script('scripts/macos-apps.sh', 'cask:google-chrome')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(name == 'podman' for name, args in self.calls()))

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_native_apply_hook_has_platform_guard_and_valid_shell(self):
        templates=self.source/'.chezmoitemplates'
        templates.mkdir()
        hook=self.repo/'home/.chezmoiscripts/run_before_15-install-macos-apps.sh.tmpl'
        shutil.copy2(hook,templates/'app-hook')
        config=self.root/'empty.toml'
        config.write_text('')
        for operating_system,architecture in [('darwin','arm64'),('darwin','amd64'),('windows','amd64'),('linux','arm64')]:
            data={'chezmoi':{'os':operating_system,'arch':architecture,'workingTree':str(self.repo)},
                  'macos':{'formulae':[],'casks':['1password-cli']}}
            template='{{ $data := '+json.dumps(json.dumps(data))+' | fromJson }}{{ includeTemplate "app-hook" $data }}'
            result=subprocess.run(['chezmoi','--source',str(self.source),'--config',str(config),'execute-template',template],
                                  env=self.env,capture_output=True,text=True,encoding='utf-8',timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            if operating_system=='darwin' and architecture=='arm64':
                self.assertIn('cask:1password-cli',result.stdout)
                syntax=subprocess.run([find_bash(),'-n'],input=result.stdout,capture_output=True,text=True)
                self.assertEqual(syntax.returncode,0,syntax.stderr)
            else:
                self.assertEqual(result.stdout.strip(),'')
