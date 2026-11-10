import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout


REPO = Path(__file__).resolve().parents[1]


class LinuxReadinessTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('linux_readiness', REPO / 'scripts/linux-readiness.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)

    def run_probe(self, args, **kwargs):
        self.assertEqual(kwargs['timeout'], 15)
        self.calls.append(args)
        if args == ['rpm', '--eval', '%{_arch}']:
            return subprocess.CompletedProcess(args, 0, self.arch, 'secret-error-value')
        if args[:2] == ['rpm', '-q']:
            return subprocess.CompletedProcess(args, 0 if self.installed else 1, 'secret-package-output', 'secret-error-value')
        self.fail(f'Unexpected executable invocation: {args}')

    def collect(self, *, available=True, installed=True, arch='x86_64', version='45', variant='kde',
                desktop='KDE', populate=True):
        self.calls, self.installed, self.arch = [], installed, arch
        if populate:
            for relative in self.module.MANAGED_FILES.values():
                file = self.home / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.touch()
        with patch.object(self.module.host.platform, 'system', return_value='Linux'), \
             patch.object(self.module.host.platform, 'freedesktop_os_release', return_value={'ID': 'fedora', 'VERSION_ID': version, 'VARIANT_ID': variant}), \
             patch.object(self.module.host.os, 'environ', {'XDG_CURRENT_DESKTOP': desktop, 'XDG_SESSION_TYPE': 'wayland'}), \
             patch.object(self.module.shutil, 'which', return_value='/secret-bearing/path' if available else None), \
             patch.object(self.module.subprocess, 'run', side_effect=self.run_probe):
            return self.module.collect(self.home)

    def test_inspection_is_pending_even_with_every_installation_present(self):
        report = self.collect()
        self.assertEqual(self.module.exit_code(report), 2)
        self.assertFalse(report['ready'])
        pending = {c['name'] for c in report['checks'] if c['status'] == 'pending'}
        self.assertFalse(any(c['status'] == 'failed' for c in report['checks']))
        self.assertIn('Minikube workload and cleanup', pending)
        self.assertIn('Secret Service and credentials', pending)
        self.assertIn('Desktop applications and vendor limitations', pending)
        self.assertIn({'name': 'KDE session', 'status': 'passed',
                       'detail': self.module.DESKTOP_DETAIL}, report['checks'])
        release = next(c for c in report['checks'] if c['name'] == 'Fedora release')
        self.assertEqual(release['status'], 'passed')
        for name in ('Hardware and install media', 'Terminal, shell and fonts', 'Native harness discovery',
                     'Authenticated harness and T3 work', 'Native builds and execution'):
            self.assertIn(name, pending)

    def test_newer_release_is_supported_and_pending_validation(self):
        report = self.collect(version='46')
        release = next(c for c in report['checks'] if c['name'] == 'Fedora release')
        self.assertEqual(release['status'], 'pending')
        self.assertIn('45', release['detail'])
        self.assertIn('46', release['detail'])
        self.assertFalse(any(c['status'] == 'failed' for c in report['checks']))
        self.assertEqual(self.module.exit_code(report), 2)

    def test_command_inventory_targets_the_fedora_kde_workstation(self):
        self.assertTrue({'podman', 'docker', 'pinentry-qt', 'kreadconfig6', 'kwriteconfig6',
                         'newuidmap', 'newgidmap'} <= set(self.module.COMMANDS))
        self.assertFalse({'dockerd', 'dockerd-rootless.sh', 'dockerd-rootless-setuptool.sh', 'rootlesskit',
                          'pinentry-gnome3', 'xdg-terminal-exec'} & set(self.module.COMMANDS))

    def test_package_inventory_targets_fedora_packages(self):
        self.assertEqual(set(self.module.PACKAGES), {
            'google-chrome-stable', '1password', '1password-cli', 'chatgpt', 'podman', 'podman-docker', 'ghostty'})

    def test_claude_desktop_is_a_recorded_limitation_not_a_package(self):
        detail = self.module.NATIVE_CHECKS['Desktop applications and vendor limitations']
        self.assertIn('Claude Desktop is unavailable on Fedora', detail)
        self.assertIn('follow-up', detail)
        self.assertNotIn('claude-desktop', self.module.PACKAGES)

    def test_native_checks_name_plasma_dolphin_and_the_podman_proof(self):
        checks = self.module.NATIVE_CHECKS
        self.assertIn('Dolphin', checks['Terminal, shell and fonts'])
        self.assertIn('Plasma', checks['Hardware and install media'])
        self.assertIn('Podman', checks['Minikube workload and cleanup'])
        self.assertIn('tests/smoke_linux_minikube.py', checks['Minikube workload and cleanup'])

    def test_missing_tools_and_managed_configuration_fail(self):
        report = self.collect(available=False, populate=False)
        self.assertEqual(self.module.exit_code(report), 1)
        for name in ('docker', 'minikube', 'codex', 'pi', 'grok', 'cc', 'dotnet'):
            self.assertIn({'name': 'Command: ' + name, 'status': 'failed',
                           'detail': self.module.MISSING_TOOL}, report['checks'])
        self.assertTrue(any(c['name'] == 'Claude instructions' and c['status'] == 'failed' for c in report['checks']))

    def test_wrong_edition_older_release_or_architecture_fails(self):
        for override in ({'variant': 'kinoite'}, {'variant': 'workstation'}, {'version': '44'}, {'arch': 'aarch64'}):
            with self.subTest(override=override):
                report = self.collect(**override)
                self.assertEqual(self.module.exit_code(report), 1)
                self.assertEqual(len(report['checks']), 1)

    def test_missing_graphical_session_is_pending(self):
        report = self.collect(desktop='')
        self.assertIn({'name': 'KDE session', 'status': 'pending',
                       'detail': self.module.DESKTOP_DETAIL}, report['checks'])
        self.assertEqual(self.module.exit_code(report), 2)

    def test_allowlisted_probes_and_sanitized_bounded_report(self):
        report = self.collect(desktop='secret-desktop-value' * 10000)
        payload = json.dumps(report)
        for value in ('secret-desktop-value', 'secret-bearing', 'secret-error-value'):
            self.assertNotIn(value, payload)
        self.assertLess(len(payload), 22000)
        self.assertTrue(self.calls)
        self.assertTrue(all(args[0] == 'rpm' for args in self.calls))

    def test_non_linux_host_does_not_execute_any_command(self):
        with patch.object(self.module.host.platform, 'system', return_value='Darwin'), \
             patch.object(self.module.subprocess, 'run') as run:
            report = self.module.collect(self.home)
        run.assert_not_called()
        self.assertEqual(self.module.exit_code(report), 1)

    def test_missing_package_and_probe_failure_are_fixed_diagnostics(self):
        for failure in ('secret-package-output', subprocess.TimeoutExpired('rpm', 15)):
            saved = self.run_probe
            def package_probe(args, **kwargs):
                if args[-1] == 'chatgpt':
                    if isinstance(failure, Exception):
                        raise failure
                    return subprocess.CompletedProcess(args, 1, failure)
                return saved(args, **kwargs)

            self.calls, self.installed, self.arch = [], True, 'x86_64'
            with patch.object(self.module.host, 'inspect_host', return_value={
                'supported': True, 'desktop': {'status': 'passed'}, 'release': {'host': 45, 'validated': 45, 'status': 'validated'}}),\
                 patch.object(self.module.subprocess, 'run', side_effect=package_probe):
                report = self.module.collect(self.home)
            self.assertEqual(self.module.exit_code(report), 1)
            self.assertTrue(any(c['name'] == 'Package: chatgpt' and c['status'] == 'failed'
                                for c in report['checks']))
            self.assertNotIn('secret-package-output', json.dumps(report))

    def test_inspection_does_not_change_home_files(self):
        self.collect()
        before = {str(p.relative_to(self.home)): p.read_bytes()
                  for p in self.home.rglob('*') if p.is_file()}
        self.collect(populate=False)
        after = {str(p.relative_to(self.home)): p.read_bytes()
                 for p in self.home.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_public_json_cli_preserves_exit_status(self):
        for status, expected in (('passed', 0), ('pending', 2), ('failed', 1)):
            report = {'ready': status == 'passed', 'checks': [
                {'name': 'fixture', 'status': status, 'detail': 'Fixed diagnostic.'}]}
            output = io.StringIO()
            with patch('sys.argv', ['linux-readiness.py', '--json']), \
                 patch.object(self.module, 'collect', return_value=report), redirect_stdout(output):
                self.assertEqual(self.module.main(), expected)
            self.assertEqual(json.loads(output.getvalue()), report)

    def test_exit_codes_require_all_checks_to_pass(self):
        for statuses, expected in ((['passed'], 0), (['pending'], 2), (['failed', 'pending'], 1)):
            report = {'ready': True, 'checks': [{'status': value} for value in statuses]}
            self.assertEqual(self.module.exit_code(report), expected)


if __name__ == '__main__':
    unittest.main()
