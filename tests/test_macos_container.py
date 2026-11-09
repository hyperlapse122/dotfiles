import json
import os
import shutil
import subprocess
import unittest

from test_macos_bootstrap import MacFixture
from test_native_ca_shell import find_bash


class MacContainerTest(MacFixture):
    def mutations(self):
        return [(name, args) for name, args in self.calls()
                if (name == 'container' and args[:2] != ['system', 'status'])
                or (name == 'brew' and args[:2] == ['services', 'start'])]

    def test_fresh_host_prepares_api_kernel_then_login_service(self):
        result = self.run_script('scripts/macos-container.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mutations(), [
            ('container', ['system', 'start', '--disable-kernel-install']),
            ('container', ['system', 'kernel', 'set', '--recommended', '--force']),
            ('brew', ['services', 'start', 'container'])])
        after = json.loads((self.root / 'state.json').read_text())
        self.assertTrue(after['kernel'])
        self.assertTrue(after['registered'])
        self.assertEqual(after['runtime'], 'running')

    def test_registered_stopped_runtime_starts_without_reregistration(self):
        self.state.update(registered=True, runtime='not running', kernel=True)
        result = self.run_script('scripts/macos-container.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mutations(), [
            ('container', ['system', 'start', '--disable-kernel-install']),
            ('container', ['system', 'kernel', 'set', '--recommended', '--force'])])

    def test_active_registered_runtime_is_unchanged_on_repeated_apply(self):
        self.state.update(registered=True, runtime='running', kernel=True)
        for _ in range(2):
            result = self.run_script('scripts/macos-container.sh')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Homebrew's fixture launcher is stopped even while the API is running.
        self.assertEqual(self.mutations(), [])

    def test_active_unregistered_runtime_only_registers_login(self):
        self.state.update(runtime='running', kernel=True)
        result = self.run_script('scripts/macos-container.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mutations(), [('brew', ['services', 'start', 'container'])])

    def test_api_start_failure_prevents_kernel_and_login_registration(self):
        self.state['fail'] = 'container system start --disable-kernel-install'
        result = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('API', result.stderr)
        self.assertEqual(len(self.mutations()), 1)
        self.assertNotIn('ready', result.stdout.lower())

    def test_kernel_failure_reports_running_api_and_skips_login_registration(self):
        self.state['fail'] = 'container system kernel set --recommended --force'
        result = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('may remain running', result.stderr)
        self.assertIn('kernel', result.stderr)
        self.assertEqual(len(self.mutations()), 2)
        after = json.loads((self.root / 'state.json').read_text())
        self.assertEqual(after['runtime'], 'running')
        self.assertFalse(after.get('registered', False))
        self.assertNotIn('ready', result.stdout.lower())

    def test_login_registration_failure_does_not_claim_readiness(self):
        self.state['fail'] = 'brew services start container'
        result = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('login', result.stderr)
        self.assertNotIn('ready', result.stdout.lower())

    def test_readiness_failure_does_not_claim_success(self):
        self.state.update(registered=True, runtime='not running', runtime_after_kernel='not running')
        result = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('respond', result.stderr)
        self.assertNotIn('ready', result.stdout.lower())

    def test_failed_kernel_cannot_be_reported_ready_on_next_apply(self):
        self.state['fail'] = 'container system kernel set --recommended --force'
        first = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(first.returncode, 0)
        self.state = json.loads((self.root / 'state.json').read_text())
        self.state.pop('fail')
        before = len(self.mutations())
        second = self.run_script('scripts/macos-container.sh')
        self.assertNotEqual(second.returncode, 0)
        self.assertIn('Previous kernel preparation', second.stderr)
        self.assertEqual(len(self.mutations()), before)
        self.assertNotIn('ready', second.stdout.lower())
        self.assertFalse(json.loads((self.root / 'state.json').read_text()).get('registered', False))

    def test_pending_preparation_can_retry_when_api_is_stopped(self):
        pending = self.root / 'state/dotfiles/container-kernel-pending'
        pending.parent.mkdir(parents=True)
        pending.touch()
        result = self.run_script('scripts/macos-container.sh')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(pending.exists())

    def test_unknown_inspection_output_prevents_all_mutations(self):
        for override in ({'runtime_json': '{}'}, {'runtime_exit': 23},
                         {'service_json': '[]'}, {'service_json': '[{"name":"container"}]'},
                         {'service_json': '[{"name":"foreign","registered":false}]'}):
            with self.subTest(override=override):
                self.state = dict(override)
                before = len(self.mutations())
                result = self.run_script('scripts/macos-container.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.mutations()), before)

    def test_unsupported_host_fails_before_mutations(self):
        for override in ({'os': 'Linux'}, {'arch': 'x86_64'}, {'version': '25.9'}):
            with self.subTest(override=override):
                self.state = dict(override)
                result = self.run_script('scripts/macos-container.sh')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.mutations(), [])

    @unittest.skipUnless(shutil.which('chezmoi'), 'Real chezmoi required')
    def test_native_hook_platform_guard_preview_and_repeated_apply(self):
        templates = self.source / '.chezmoitemplates'
        templates.mkdir()
        config = self.root / 'empty.toml'
        config.write_text('[interpreters.sh]\ncommand = ' + json.dumps(find_bash()) +
                          '\nargs = ' + json.dumps(self.shell_arguments()) + '\n')
        hooks = ['run_before_15-install-macos-apps.sh.tmpl', 'run_before_16-prepare-macos-container.sh.tmpl']
        scripts = self.source / '.chezmoiscripts'
        scripts.mkdir()
        for hook in hooks:
            shutil.copy2(self.repo / 'home/.chezmoiscripts' / hook, templates / hook)
            for operating_system, architecture in [('darwin', 'arm64'), ('darwin', 'amd64'), ('windows', 'amd64'), ('linux', 'arm64')]:
                data = {'chezmoi': {'os': operating_system, 'arch': architecture, 'workingTree': str(self.repo)},
                        'macos': {'formulae': ['container'], 'casks': []}}
                template = '{{ $data := ' + json.dumps(json.dumps(data)) + ' | fromJson }}{{ includeTemplate "' + hook + '" $data }}'
                result = subprocess.run(['chezmoi', '--source', str(self.source), '--config', str(config),
                                         'execute-template', template], env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if (operating_system, architecture) == ('darwin', 'arm64'):
                    syntax = subprocess.run([find_bash(), '-n'], input=result.stdout, capture_output=True, text=True)
                    self.assertEqual(syntax.returncode, 0, syntax.stderr)
                    (scripts / hook.removesuffix('.tmpl')).write_text(result.stdout)
                else:
                    self.assertEqual(result.stdout.strip(), '')
        self.assertEqual(self.calls(), [])
        (self.root / 'state.json').write_text(json.dumps(self.state))
        command = [shutil.which('chezmoi'), '--source', str(self.source), '--destination', str(self.home), '--config', str(config),
                   '--cache', str(self.root / 'cache'), '--persistent-state', str(self.root / 'chezmoi-state.boltdb'), '--no-tty']
        env = dict(self.env, PATH=str(self.bin))
        preview = subprocess.run([*command, 'diff'], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertEqual(self.calls(), [])
        for _ in range(2):
            result = subprocess.run([*command, 'apply'], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        first_upgrade = calls.index(['brew', ['upgrade', '--yes']])
        first_start = calls.index(['container', ['system', 'start', '--disable-kernel-install']])
        self.assertLess(first_upgrade, first_start)
        self.assertEqual(len(self.mutations()), 3)
        after = json.loads((self.root / 'state.json').read_text())
        self.assertTrue(after['registered'])
        self.assertEqual(after['runtime'], 'running')
        self.assertFalse(after['container_upgraded'])
        self.assertEqual(after['pins'], [])
