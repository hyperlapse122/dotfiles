import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'retire-t3'
MERGER = ROOT / 'scripts' / 'agent-settings'

SETTINGS_REMOVAL = {
    'remove': [
        'defaultThreadEnvMode',
        'threadTitleInstructions',
        'defaultModelSelection',
    ],
    'removePaths': [
        {'path': ['storageCleanup'], 'key': 'worktreeAfterDays', 'value': 5, 'prune': True},
        {'path': ['providerInstances', 'claudeAgent'], 'key': 'driver',
         'value': 'claudeAgent', 'prune': True},
        {'path': ['providerInstances', 'claudeAgent'], 'key': 'enabled',
         'value': True, 'prune': True},
        {'path': ['providerInstances', 'claudeAgent', 'config'], 'key': 'idleCompaction',
         'value': 'beforeCacheExpires', 'prune': True},
    ],
    'removeEntries': [
        {'path': ['providerInstances', 'opencode', 'environment'],
         'key': 'name', 'values': ['OPENCODE_CONFIG_CONTENT']},
    ],
}

CLIENT_REMOVAL = {'remove': ['fontFamilySans']}


class RetireT3Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.userdata = self.home / '.t3' / 'userdata'
        self.userdata.mkdir(parents=True)
        self.settings = self.userdata / 'settings.json'
        self.client = self.userdata / 'client-settings.json'
        self.state = self.userdata / 'dotfiles-launch-state.json'
        self.instructions = self.userdata / 'instructions'
        self.instructions.mkdir()
        self.marker = self.userdata / '.t3-retirement-complete'
        self.declarations = self.home / 'declarations'
        self.declarations.mkdir()
        self.settings_declaration = self.declarations / 'settings.json'
        self.client_declaration = self.declarations / 'client.json'
        self.settings_declaration.write_text(json.dumps(SETTINGS_REMOVAL))
        self.client_declaration.write_text(json.dumps(CLIENT_REMOVAL))
        self.merger = self.home / 'merger'
        self.merger.write_text(
            '#!/bin/sh\nexec {} {} "$@"\n'.format(sys.executable, MERGER)
        )
        self.merger.chmod(0o755)

    def seed(self):
        self.settings.write_text(json.dumps({
            'defaultThreadEnvMode': 'worktree',
            'threadTitleInstructions': 'declared',
            'defaultModelSelection': {'model': 'declared'},
            'userOnly': {'keep': True},
            'storageCleanup': {'worktreeAfterDays': 5, 'userSetting': 9},
            'providerInstances': {
                'claudeAgent': {
                    'driver': 'claudeAgent',
                    'enabled': True,
                    'config': {
                        'idleCompaction': 'beforeCacheExpires',
                        'launchArgs': '--append-system-prompt-file "{}"'.format(
                            self.instructions / 'claude.md'
                        ),
                    },
                    'userField': 'keep',
                },
                'opencode': {
                    'driver': 'opencode',
                    'enabled': True,
                    'environment': [
                        {'name': 'OPENCODE_CONFIG_CONTENT', 'value': 'declared'},
                        {'name': 'USER_ENV', 'value': 'keep'},
                    ],
                },
            },
        }))
        self.client.write_text(json.dumps({
            'fontFamilySans': 'declared',
            'userFont': 'keep',
            'providerModelPreferences': {
                'pi': {'hiddenModels': ['default', 'model-x', 'user-model']},
            },
        }))
        self.state.write_text(json.dumps({
            'schema': 1,
            'providers': {
                'claudeAgent': {
                    'baseArgs': '--add-dir base',
                    'hadArgs': True,
                    'lastArgs': '--add-dir base --append-system-prompt-file "{}"'.format(
                        self.instructions / 'claude.md'
                    ),
                    'controlArgs': [],
                    'baseEnvironment': [],
                    'hadEnvironment': False,
                    'lastEnvironment': [],
                },
            },
        }))
        for name in ('claude.md', 'pi.md', 'opencode.md', 'user.md'):
            (self.instructions / name).write_text(name)
        (self.userdata / 't3code-settings-ownership.json').write_text('{}')

    def run_helper(self):
        return subprocess.run(
            [
                sys.executable,
                SCRIPT,
                '--home', self.home,
                '--merger', self.merger,
                '--settings-declaration', self.settings_declaration,
                '--client-declaration', self.client_declaration,
                '--hidden-model', 'model-x',
            ],
            text=True,
            capture_output=True,
        )

    def test_cleanup_removes_declared_and_preserves_user_state(self):
        self.seed()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(self.settings.read_text())
        client = json.loads(self.client.read_text())
        self.assertNotIn('defaultThreadEnvMode', settings)
        self.assertNotIn('threadTitleInstructions', settings)
        self.assertNotIn('defaultModelSelection', settings)
        self.assertEqual(settings['userOnly'], {'keep': True})
        self.assertEqual(settings['storageCleanup'], {'userSetting': 9})
        claude = settings['providerInstances']['claudeAgent']
        self.assertNotIn('driver', claude)
        self.assertNotIn('enabled', claude)
        self.assertNotIn('idleCompaction', claude['config'])
        self.assertEqual(claude['userField'], 'keep')
        opencode = settings['providerInstances']['opencode']
        self.assertEqual(opencode['environment'], [{'name': 'USER_ENV', 'value': 'keep'}])
        self.assertNotIn('fontFamilySans', client)
        self.assertEqual(client['userFont'], 'keep')
        self.assertEqual(client['providerModelPreferences']['pi']['hiddenModels'], ['user-model'])
        self.assertFalse(self.state.exists())
        self.assertFalse((self.userdata / 't3code-settings-ownership.json').exists())
        self.assertEqual(sorted(path.name for path in self.instructions.iterdir()), ['user.md'])
        self.assertTrue(self.marker.exists())

    def test_launch_arguments_are_restored_from_the_recorded_base(self):
        self.seed()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(self.settings.read_text())
        self.assertEqual(
            settings['providerInstances']['claudeAgent']['config']['launchArgs'],
            '--add-dir base',
        )

    def test_missing_t3_directory_is_a_noop(self):
        empty = Path(self.tmp.name) / 'empty'
        empty.mkdir()
        result = subprocess.run(
            [
                sys.executable,
                SCRIPT,
                '--home', empty,
                '--merger', self.merger,
                '--settings-declaration', self.settings_declaration,
                '--client-declaration', self.client_declaration,
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((empty / '.t3').exists())

    def test_malformed_settings_leave_every_file_untouched(self):
        self.seed()
        self.settings.write_text('{', encoding='utf-8')
        before = self.settings.read_bytes()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse(self.marker.exists())

    def test_second_run_changes_nothing(self):
        self.seed()
        self.assertEqual(self.run_helper().returncode, 0)
        before = {
            path: (path.stat().st_ino, path.stat().st_mtime_ns)
            for path in (self.settings, self.client, self.marker)
        }
        self.assertEqual(self.run_helper().returncode, 0)
        after = {
            path: (path.stat().st_ino, path.stat().st_mtime_ns)
            for path in (self.settings, self.client, self.marker)
        }
        self.assertEqual(before, after)

    def test_a_run_without_the_marker_retries_cleanly(self):
        self.seed()
        self.assertEqual(self.run_helper().returncode, 0)
        self.marker.unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        settings = json.loads(self.settings.read_text())
        self.assertNotIn('defaultThreadEnvMode', settings)


if __name__ == '__main__':
    unittest.main()
