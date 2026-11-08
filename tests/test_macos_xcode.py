import importlib.util
import io
import os
from pathlib import Path
import plistlib
import platform
import shutil
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

    def test_overlapping_credentials_never_expose_the_password_suffix(self):
        for chunks in [(b'owner-private-suffix\nEnter code: ',),
                       (b'owner', b'-private-', b'suffix\nEnter code: ')]:
            with self.subTest(chunks=chunks):
                filter_ = xcode.Redactor(['owner', 'owner-private-suffix'])
                output = b''.join(filter_.feed(chunk) for chunk in chunks) + filter_.finish()
                self.assertEqual(output, b'[redacted]\nEnter code: ')

    def test_first_and_later_prerelease_install_arguments_match_the_pinned_tool(self):
        for channel, sequence, expected in [('release', True, '27.3'), ('beta', 1, '27.3 Beta'),
                                             ('beta', 3, '27.3 Beta 3'), ('rc', 1, '27.3 Release Candidate'),
                                             ('rc', 2, '27.3 Release Candidate 2'), ('dp', 1, '27.3 DP')]:
            with self.subTest(channel=channel, sequence=sequence), \
                 mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.3', channel, sequence)]), \
                 mock.patch.object(xcode, 'host_version', return_value='26.6'), \
                 mock.patch.object(xcode, 'installed_candidate', return_value=None), \
                 mock.patch.object(xcode.apple_account, 'read_account', return_value={'username': 'fixture-user', 'password': 'fixture-password'}), \
                 mock.patch.object(xcode, 'run_interactive', side_effect=xcode.XcodeError('stop after argument capture')) as install, \
                 mock.patch.object(sys, 'stdout', io.StringIO()):
                with self.assertRaises(xcode.XcodeError):
                    xcode.update(Path('.'))
                self.assertEqual(install.call_args.args[0][2], expected)

    def test_real_candidate_verification_prevents_selection_on_native_failures(self):
        app = Path('/Applications/Xcode-fixture.app')
        developer = str(app / 'Contents/Developer')
        for failure in ['signature', 'first-launch', 'sdk', None]:
            calls = []
            selected = []
            def native(argv, **kwargs):
                calls.append(argv)
                status, output = 0, ''
                if 'codesign' in argv[0] and failure == 'signature':
                    status = 1
                elif '-checkFirstLaunchStatus' in argv and failure == 'first-launch':
                    status = 1
                elif '--find' in argv:
                    output = '/fixture/clang'
                elif '--show-sdk-path' in argv:
                    output = '' if failure == 'sdk' else '/fixture/MacOSX.sdk'
                elif '--print-path' in argv:
                    output = '/old/developer'
                return subprocess.CompletedProcess(argv, status, output, '')
            def interactive(argv, **kwargs):
                if '-license' in argv:
                    raise xcode.XcodeError('first-launch failed')
                selected.append(argv)
            with self.subTest(failure=failure), \
                 mock.patch.object(xcode, 'fetch_catalog', return_value=[release('27.1')]), \
                 mock.patch.object(xcode, 'host_version', return_value='26.6'), \
                 mock.patch.object(xcode, 'installed_candidate', return_value=app), \
                 mock.patch.object(xcode.subprocess, 'run', side_effect=native), \
                 mock.patch.object(xcode, 'run_interactive', side_effect=interactive), \
                 mock.patch.object(xcode.apple_account, 'read_account') as secrets, \
                 mock.patch.object(sys, 'stdout', io.StringIO()):
                if failure is not None:
                    with self.assertRaises(xcode.XcodeError):
                        xcode.update(Path('.'))
                    self.assertEqual(selected, [])
                else:
                    xcode.update(Path('.'))
                    self.assertEqual(selected, [['/usr/bin/sudo', '/usr/bin/xcode-select', '--switch', developer]])
                    self.assertTrue(any('codesign' in argv[0] for argv in calls))
                    self.assertTrue(any('-checkFirstLaunchStatus' in argv for argv in calls))
                    self.assertTrue(any('--show-sdk-path' in argv for argv in calls))
                secrets.assert_not_called()

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
                            'import ctypes;libc=ctypes.CDLL(None);libc.printf(b"Enter code: ");libc.getchar()'])
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


@unittest.skipUnless(os.name != 'nt' and shutil.which('chezmoi'), 'POSIX chezmoi required')
class XcodeApplyTest(unittest.TestCase):
    def test_every_explicit_apply_runs_update_with_source_and_config(self):
        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="xcode apply ' ") as directory:
            root = Path(directory)
            source = root / 'source'
            scripts = source / 'home/.chezmoiscripts'
            scripts.mkdir(parents=True)
            (source / '.chezmoiroot').write_text('home')
            shutil.copy2(repo / 'home/.chezmoiscripts/run_before_18-update-xcode.sh.tmpl', scripts)
            home = root / 'home'
            home.mkdir()
            config = root / 'chezmoi.toml'
            config.write_text('')
            commands = root / 'commands'
            commands.mkdir()
            mise = commands / 'mise'
            mise.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                            'with open(os.environ["XCODE_CALLS"],"a") as stream: stream.write(json.dumps(sys.argv[1:])+"\\n")\n')
            mise.chmod(0o755)
            log = root / 'calls'
            env = os.environ | {'HOME': str(home), 'PATH': str(commands) + os.pathsep + os.environ['PATH'], 'XCODE_CALLS': str(log)}
            argv = ['chezmoi', '--source', str(source / 'home'), '--working-tree', str(source),
                    '--destination', str(home), '--config', str(config), '--cache', str(root / 'cache'),
                    '--persistent-state', str(root / 'state'), 'apply', '--force']
            for _ in range(2):
                subprocess.run(argv, env=env, capture_output=True, check=True)
            if platform.system() == 'Darwin' and platform.machine() == 'arm64':
                import json
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0], ['--cd', str(source), 'exec', '--', 'python',
                                         str(source / 'scripts/macos-xcode.py'), '--source', str(source),
                                         '--config', str(config)])
            else:
                self.assertFalse(log.exists())


if __name__ == '__main__':
    unittest.main()
