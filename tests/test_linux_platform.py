import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


REPO = Path(__file__).resolve().parents[1]


def load_platform():
    spec = importlib.util.spec_from_file_location('linux_platform', REPO / 'scripts/linux-platform.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATED = load_platform().VALIDATED_RELEASE


def fedora(**overrides):
    release = {'ID': 'fedora', 'VERSION_ID': str(VALIDATED), 'VARIANT_ID': 'kde',
               'PRETTY_NAME': f'Fedora Linux {VALIDATED} (KDE Plasma Desktop Edition)'}
    release.update(overrides)
    return {key: value for key, value in release.items() if value is not None}


class LinuxPlatformTest(unittest.TestCase):
    def inspect(self, *, system='Linux', release=None, arch='x86_64', ostree=False, env=None):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            self.assertEqual(args, ['rpm', '--eval', '%{_arch}'])
            return subprocess.CompletedProcess(args, 0, arch + '\n', '')

        report = load_platform().inspect_host(system=system, os_release=fedora() if release is None else release,
                                              environ=env or {}, run=run, ostree_booted=ostree)
        return report

    def test_validated_fedora_kde_is_supported(self):
        report = self.inspect(env={'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'})
        self.assertTrue(report['supported'])
        self.assertEqual(report['blockers'], [])
        self.assertEqual(report['desktop']['status'], 'passed')
        self.assertEqual(report['release'], {'host': VALIDATED, 'validated': VALIDATED, 'status': 'validated'})
        self.assertEqual(report['evidence']['variant_id'], 'kde')
        self.assertEqual(report['evidence']['architecture'], 'x86_64')

    def test_newer_release_is_supported_and_unvalidated(self):
        report = self.inspect(release=fedora(VERSION_ID=str(VALIDATED + 1)))
        self.assertTrue(report['supported'])
        self.assertEqual(report['release']['status'], 'unvalidated')
        self.assertEqual(report['release']['host'], VALIDATED + 1)

    def test_older_release_is_unsupported(self):
        report = self.inspect(release=fedora(VERSION_ID=str(VALIDATED - 1)))
        self.assertFalse(report['supported'])
        self.assertIn(str(VALIDATED), ' '.join(report['blockers']))
        self.assertEqual(report['release']['status'], 'unsupported')

    def test_atomic_desktops_are_unsupported(self):
        for override in ({'release': fedora(VARIANT_ID='kinoite')}, {'ostree': True}):
            with self.subTest(override=override):
                report = self.inspect(**override)
                self.assertFalse(report['supported'])
                self.assertIn('atomic', ' '.join(report['blockers']).lower())

    def test_other_editions_are_unsupported(self):
        for variant in ('workstation', 'server', None):
            with self.subTest(variant=variant):
                report = self.inspect(release=fedora(VARIANT_ID=variant))
                self.assertFalse(report['supported'])
                self.assertIn('KDE Plasma Desktop', ' '.join(report['blockers']))

    def test_unsupported_hosts_each_name_a_blocker(self):
        for override, expected in (({'system': 'Darwin'}, 'Linux'), ({'arch': 'aarch64'}, 'x86_64'),
                                   ({'release': {'ID': 'ubuntu', 'VERSION_ID': '26.04'}}, 'Fedora'),
                                   ({'release': {'ID': 'ubuntu', 'VERSION_ID': str(VALIDATED)}}, 'Fedora'),
                                   ({'release': {}}, 'Fedora')):
            with self.subTest(override=override):
                report = self.inspect(**override)
                self.assertFalse(report['supported'])
                self.assertIn(expected, ' '.join(report['blockers']))

    def test_non_numeric_release_is_unsupported_without_error(self):
        for version in ('rawhide', '', None):
            with self.subTest(version=version):
                report = self.inspect(release=fedora(VERSION_ID=version))
                self.assertFalse(report['supported'])
                self.assertIsNone(report['release']['host'])

    def test_desktop_is_separate_from_host_support(self):
        for env in ({}, {'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'wayland'},
                    {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'tty'}):
            with self.subTest(env=env):
                report = self.inspect(env=env)
                self.assertTrue(report['supported'])
                self.assertEqual(report['desktop']['status'], 'pending')
        report = self.inspect(env={'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'x11'})
        self.assertEqual(report['desktop']['status'], 'passed')

    def test_missing_or_failing_architecture_probe_fails_closed(self):
        def missing(*args, **kwargs):
            raise FileNotFoundError('rpm')

        def failing(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, '', 'error')

        for run in (missing, failing):
            report = load_platform().inspect_host(system='Linux', os_release=fedora(), environ={}, run=run,
                                                  ostree_booted=False)
            self.assertFalse(report['supported'])

    def test_cli_emits_json_on_native_host(self):
        result = subprocess.run([sys.executable, str(REPO / 'scripts/linux-platform.py')], capture_output=True, text=True, timeout=15)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if report['supported'] else 1)
        self.assertIn('desktop', report)
        self.assertIn('release', report)


if __name__ == '__main__':
    unittest.main()
