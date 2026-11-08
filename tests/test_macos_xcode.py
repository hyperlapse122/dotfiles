import importlib.util
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
SPEC = importlib.util.spec_from_file_location('macos_xcode', Path(__file__).resolve().parents[1] / 'scripts/macos-xcode.py')
xcode = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(xcode)


def release(number, channel='release', sequence=True, requires='26.0', build='27A1', arch=None):
    download = {'url': 'https://download.developer.apple.com/fixture.xip'}
    if arch is not None:
        download['architectures'] = arch
    return {'name': 'Xcode', 'version': {'number': number, 'build': build, 'release': {channel: sequence}},
            'requires': requires, 'links': {'download': download}}


class XcodeReleaseTest(unittest.TestCase):
    def test_latest_is_numeric_version_then_final_rc_beta_not_date(self):
        catalog = [release('27.9'), release('27.10', 'beta', 2), release('27.10', 'rc', 1)]
        self.assertEqual(xcode.latest(catalog)['version']['release'], {'rc': 1})
        catalog.append(release('27.10'))
        self.assertEqual(xcode.latest(catalog)['version']['release'], {'release': True})
        self.assertEqual(xcode.latest([release('27.2'), release('27.3', 'beta', 1)])['version']['number'], '27.3')

    def test_architecture_and_invalid_highest_metadata_do_not_hide_newest(self):
        self.assertEqual(xcode.latest([release('27.1'), release('27.2', arch=['x86_64'])])['version']['number'], '27.1')
        with self.assertRaises(xcode.XcodeError):
            xcode.latest([release('27.1'), release('27.2', requires=None)])

    def test_incompatible_os_stops_before_secrets_or_install(self):
        with mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.3', requires='26.6')]), \
             mock.patch.object(xcode, 'host_version', return_value='26.5'), \
             mock.patch.object(xcode.apple_account, 'read_account') as secrets, \
             mock.patch.object(xcode, 'run_interactive') as install:
            with self.assertRaisesRegex(xcode.XcodeError, '26.6'):
                xcode.update(Path('.'))
            secrets.assert_not_called()
            install.assert_not_called()

    def test_failed_candidate_verification_keeps_previous_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Xcode-fixture.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.apple.dt.Xcode', 'CFBundleShortVersionString': '27.1'}))
            (app / 'Contents/version.plist').write_bytes(plistlib.dumps({'ProductBuildVersion': '27A1'}))
            with mock.patch.object(xcode, 'APPLICATIONS', root), \
                 mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.1')]), \
                 mock.patch.object(xcode, 'host_version', return_value='26.6'), \
                 mock.patch.object(xcode, 'verify_candidate', side_effect=xcode.XcodeError('Invalid signature')), \
                 mock.patch.object(xcode, 'run_interactive') as commands, \
                 mock.patch.object(xcode.apple_account, 'read_account') as secrets:
                with self.assertRaises(xcode.XcodeError):
                    xcode.update(Path('.'))
                commands.assert_not_called()
                secrets.assert_not_called()

    def test_redaction_handles_credentials_split_across_chunks(self):
        filter_ = xcode.Redactor(['owner@example.invalid', 'secret-password'])
        output = b''.join(filter_.feed(chunk) for chunk in [b'Using ow', b'ner@example.invalid: sec', b'ret-pass', b'word\nEnter code: ']) + filter_.finish()
        self.assertEqual(output, b'Using [redacted]: [redacted]\nEnter code: ')

    def test_install_verifies_build_before_switching_and_reuse_needs_no_secret(self):
        app = Path('/Applications/Xcode-fixture.app')
        events = []
        def interactive(argv, **kwargs):
            events.append('select' if '--switch' in argv else 'install')
            if 'install' in argv:
                self.assertNotIn('--select', argv)
                self.assertEqual(kwargs['env']['XCODES_PASSWORD'], 'fixture-password')
                self.assertNotIn('DEVELOPER_DIR', kwargs['env'])
        with mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.1')]), \
             mock.patch.object(xcode, 'host_version', return_value='26.6'), \
             mock.patch.object(xcode, 'installed_candidate', side_effect=[None, app]), \
             mock.patch.object(xcode.apple_account, 'read_account', return_value={'username': 'fixture-user', 'password': 'fixture-password'}), \
             mock.patch.object(xcode, 'verify_candidate', side_effect=lambda app: events.append('verify')), \
             mock.patch.object(xcode, 'run_command', return_value=subprocess.CompletedProcess([], 0, '/old/developer\n')), \
             mock.patch.object(xcode, 'run_interactive', side_effect=interactive), \
             mock.patch.dict(os.environ, {'DEVELOPER_DIR': '/incorrect/override'}), \
             mock.patch.object(sys, 'stdout', io.StringIO()):
            xcode.update(Path('.'))
        self.assertEqual(events, ['install', 'verify', 'select'])

    def test_failed_download_does_not_verify_or_switch(self):
        with mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.1')]), \
             mock.patch.object(xcode, 'host_version', return_value='26.6'), \
             mock.patch.object(xcode, 'installed_candidate', return_value=None), \
             mock.patch.object(xcode.apple_account, 'read_account', return_value={'username': 'fixture-user', 'password': 'fixture-password'}), \
             mock.patch.object(xcode, 'run_interactive', side_effect=xcode.XcodeError('download failed')) as install, \
             mock.patch.object(xcode, 'verify_candidate') as verify, \
             mock.patch.object(sys, 'stdout', io.StringIO()):
            with self.assertRaises(xcode.XcodeError):
                xcode.update(Path('.'))
            self.assertEqual(install.call_count, 1)
            self.assertIn('install', install.call_args.args[0])
            verify.assert_not_called()

    @unittest.skipIf(os.name == 'nt', 'POSIX interactive installer')
    def test_unterminated_prompt_is_visible_before_input(self):
        import pty
        master, slave = pty.openpty()
        visible = threading.Event()

        class Output(io.StringIO):
            def write(self, value):
                result = super().write(value)
                if 'Enter code: ' in self.getvalue():
                    visible.set()
                return result

        output = Output()
        errors = []
        with os.fdopen(os.dup(slave)) as terminal:
            def run():
                try:
                    with mock.patch.object(sys, 'stdin', terminal), mock.patch.object(sys, 'stdout', output):
                        xcode.run_interactive([sys.executable, '-c',
                            'import sys;sys.stdout.write("Enter code: ");sys.stdout.flush() if sys.stdout.isatty() else None;input()'])
                except Exception as error:
                    errors.append(error)
            thread = threading.Thread(target=run)
            thread.start()
            try:
                self.assertTrue(visible.wait(5), 'Prompt was buffered while the child waited for input')
            finally:
                os.write(master, b'123456\n')
                thread.join(5)
                os.close(master)
                os.close(slave)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
