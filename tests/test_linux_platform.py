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


class LinuxPlatformTest(unittest.TestCase):
    def inspect(self, *, system='Linux', release=None, arch='amd64', packages=('ubuntu-desktop',), env=None):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if args == ['dpkg', '--print-architecture']:
                return subprocess.CompletedProcess(args, 0, arch, '')
            self.assertEqual(args[:3], ['dpkg-query', '-W', '-f=${Status}'])
            return subprocess.CompletedProcess(args, 0 if args[-1] in packages else 1,
                                               'install ok installed\n' if args[-1] in packages else '', '')

        report = load_platform().inspect_host(system=system, os_release={
            'ID': 'ubuntu', 'VERSION_ID': '26.04', 'PRETTY_NAME': 'Ubuntu 26.04.1 LTS'} if release is None else release,
            environ=env or {}, run=run)
        self.assertTrue(all(call[0] in ('dpkg', 'dpkg-query') for call in calls))
        return report

    def test_supported_ubuntu_desktop_metapackages(self):
        for package in ('ubuntu-desktop', 'ubuntu-desktop-minimal'):
            with self.subTest(package=package):
                report = self.inspect(packages=(package,), env={'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME', 'XDG_SESSION_TYPE': 'wayland'})
                self.assertTrue(report['supported'])
                self.assertEqual(report['desktop']['status'], 'passed')
                self.assertEqual(report['blockers'], [])
                self.assertEqual(report['evidence']['desktop_packages'], [package])

    def test_studio_metapackage_alone_is_unsupported(self):
        report = self.inspect(packages=('ubuntustudio-desktop',))
        self.assertFalse(report['supported'])
        self.assertIn('ubuntu-desktop', ' '.join(report['blockers']))

    def test_unsupported_hosts(self):
        for override in ({'system': 'Darwin'}, {'arch': 'arm64'}, {'packages': ()},
                         {'release': {'ID': 'ubuntu', 'VERSION_ID': '24.04'}},
                         {'release': {'ID': 'ubuntu', 'VERSION_ID': '26.10'}},
                         {'release': {'ID': 'debian', 'VERSION_ID': '26.04'}}, {'release': {}}):
            with self.subTest(override=override):
                report = self.inspect(**override)
                self.assertFalse(report['supported'])
                self.assertTrue(report['blockers'])

    def test_desktop_is_separate_from_host_support(self):
        for env in ({}, {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'},
                    {'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME', 'XDG_SESSION_TYPE': 'tty'}):
            report = self.inspect(env=env)
            self.assertTrue(report['supported'])
            self.assertEqual(report['desktop']['status'], 'pending')

    def test_missing_native_probes_fail_closed(self):
        def missing(*args, **kwargs):
            raise FileNotFoundError('dpkg')
        report = load_platform().inspect_host(system='Linux', os_release={'ID': 'ubuntu', 'VERSION_ID': '26.04'}, environ={}, run=missing)
        self.assertFalse(report['supported'])

    def test_removed_metapackage_is_not_installed(self):
        def removed(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, 'amd64' if args[0] == 'dpkg' else 'deinstall ok config-files', '')
        report = load_platform().inspect_host(system='Linux', os_release={'ID': 'ubuntu', 'VERSION_ID': '26.04'}, environ={}, run=removed)
        self.assertFalse(report['supported'])

    def test_cli_emits_json_on_native_host(self):
        result = subprocess.run([sys.executable, str(REPO / 'scripts/linux-platform.py')], capture_output=True, text=True, timeout=15)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if report['supported'] else 1)
        self.assertIn('desktop', report)


if __name__ == '__main__':
    unittest.main()
