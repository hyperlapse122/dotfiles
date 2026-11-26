import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


class T3InstructionsTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('t3_instructions', Path(os.environ.get('T3_INSTRUCTIONS_SCRIPT', str(REPO / 'scripts/t3-instructions.py'))))
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        scratch = tempfile.TemporaryDirectory(prefix="t3 instructions ' ")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        self.settings = self.home / '.t3/userdata/settings.json'
        self.instructions = self.settings.parent / 'instructions'
        self.instructions.mkdir(parents=True)
        for name in ('claude', 'pi'):
            (self.instructions / (name + '.md')).write_text('T3_' + name + '\nQuoted "text", apostrophe\'s.\n')

    def write(self, value):
        self.settings.write_text(json.dumps(value))

    def read(self):
        return json.loads(self.settings.read_text())

    def test_client_hidden_choices_preserve_user_state(self):
        client = self.settings.with_name('client-settings.json')
        kept = 'synthetic/syn:small:vision'
        added = 'synthetic/infinite:small:vision'
        client.write_text(json.dumps({'providerModelPreferences': {'pi': {
            'hiddenModels': ['user-hidden', kept], 'modelOrder': ['custom']}}}))
        for _ in range(2):
            self.module.apply(self.home, hidden_models=[kept, added])
            self.assertEqual(json.loads(client.read_text())['providerModelPreferences']['pi'], {
                'hiddenModels': ['user-hidden', kept, 'default', added], 'modelOrder': ['custom']})

    def test_fresh_launches_and_claude_depth_respect_user_settings(self):
        for file in self.instructions.iterdir():
            file.write_text('')
        self.write({'providerInstances': {
            'claudeAgent': {'config': {'launchArgs': '--disallowedTools Read Edit'}},
            'pi': {'config': {'launchArgs': '--thinking low'}},
        }})
        self.module.apply(self.home)
        providers = self.read()['providerInstances']
        self.assertEqual(providers['claudeAgent']['config']['launchArgs'], '--disallowedTools Read Edit')
        self.assertEqual(providers['claudeAgent']['environment'], [
            {'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '', 'sensitive': False}])
        self.assertEqual(self.module.tokenize(providers['pi']['config']['launchArgs']), ['--thinking', 'low', '--approve'])
        providers['claudeAgent']['environment'] = [{'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '3'}]
        self.write({'providerInstances': providers})
        self.module.apply(self.home)
        self.assertEqual(self.read()['providerInstances']['claudeAgent']['environment'],
                         [{'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '3'}])

    def test_empty_claude_addition_without_state_removes_only_managed_arguments(self):
        user_file = self.home / 'user append.md'
        user_file.write_text('User-owned instructions\n')
        managed_addition = self.instructions / 'claude.md'
        managed_addition.write_text('')
        user_arguments = [
            '--append-system-prompt-file', str(user_file),
            '--append-system-prompt', 'User-owned inline instructions',
            '--disallowedTools', 'Read',
        ]
        self.write({'providerInstances': {'claudeAgent': {
            'config': {
                'launchArgs': self.module.join_args(user_arguments + [
                    '--append-system-prompt-file', str(managed_addition),
                ]),
            },
            'environment': [{
                'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '', 'sensitive': False,
            }],
        }}})
        self.module.apply(self.home)
        result = self.read()['providerInstances']['claudeAgent']
        self.assertEqual(self.module.tokenize(result['config']['launchArgs']), user_arguments)
        state = json.loads(self.settings.with_name('dotfiles-launch-state.json').read_text())
        self.assertNotIn('claudeAgent', state['providers'])
        settings_before = self.settings.read_bytes()
        state_before = self.settings.with_name('dotfiles-launch-state.json').read_bytes()
        self.module.apply(self.home)
        self.assertEqual(self.settings.read_bytes(), settings_before)
        self.assertEqual(self.settings.with_name('dotfiles-launch-state.json').read_bytes(), state_before)

    def test_schema_one_migration_preserves_user_controls_and_later_duplicates(self):
        name = 'claudeAgent'
        base = ['--disallowedTools', 'Read']
        managed = ['--disallowedTools=Read,Agent']
        later = ['--disallowedTools=Read,Agent']
        for edited in (False, True):
            with self.subTest(edited=edited):
                old_args = managed + ['--append-system-prompt-file', str(self.instructions / 'claude.md')]
                current = old_args + (later if edited else [])
                self.write({'providerInstances': {name: {'config': {'launchArgs': self.module.join_args(current)}}}})
                self.settings.with_name('dotfiles-launch-state.json').write_text(json.dumps({'schema': 1, 'providers': {name: {
                    'baseArgs': self.module.join_args(base), 'lastArgs': self.module.join_args(old_args), 'hadArgs': True,
                    'controlArgs': [managed], 'controlBaseArgs': base,
                    'baseEnvironment': [], 'lastEnvironment': [], 'hadEnvironment': False}}}))
                self.module.apply(self.home)
                args = self.module.tokenize(self.read()['providerInstances'][name]['config']['launchArgs'])
                self.assertEqual(args[:len(base) + (len(later) if edited else 0)], base + (later if edited else []))

    def test_ambiguous_old_control_is_preserved(self):
        current = '--disallowedTools=Agent --disallowedTools=Agent'
        self.write({'providerInstances': {'claudeAgent': {'config': {'launchArgs': current}}}})
        self.settings.with_name('dotfiles-launch-state.json').write_text(json.dumps({'schema': 1, 'providers': {'claudeAgent': {
            'baseArgs': '', 'lastArgs': '--disallowedTools=Agent', 'hadArgs': False,
            'controlArgs': [['--disallowedTools=Agent']], 'controlBaseArgs': [],
            'baseEnvironment': [], 'lastEnvironment': [], 'hadEnvironment': False}}}))
        self.module.apply(self.home)
        args = self.module.tokenize(self.read()['providerInstances']['claudeAgent']['config']['launchArgs'])
        self.assertEqual(args.count('--disallowedTools=Agent'), 2)

    def test_existing_context_is_composed_once_and_removal_restores_user_settings(self):
        existing = self.home / "user's append.md"
        existing.write_text('Existing Claude file\n')
        original = {'unrelated': [1, None], 'providerInstances': {
            'claudeAgent': {'config': {'launchArgs': self.module.join_args([
                '--append-system-prompt-file', str(existing), '--append-system-prompt', 'Existing Claude inline'])}},
            'pi': {'config': {'launchArgs': '--append-system-prompt relative-project.md --thinking low'}},
        }}
        self.write(original)
        self.module.apply(self.home)
        result = self.read()['providerInstances']
        claude = self.module.tokenize(result['claudeAgent']['config']['launchArgs'])
        self.assertEqual(claude[-4:-2], ['--append-system-prompt-file', str(self.instructions / 'claude.md')])
        self.assertIn('Existing Claude file', claude[-1])
        self.assertIn('Existing Claude inline', claude[-1])
        self.assertNotIn('Existing Claude', (self.instructions / 'claude.md').read_text())
        pi = self.module.tokenize(result['pi']['config']['launchArgs'])
        self.assertEqual(pi[:4], ['--append-system-prompt', 'relative-project.md', '--thinking', 'low'])
        self.assertEqual(pi[-2:], ['--append-system-prompt', str(self.instructions / 'pi.md')])
        before = self.settings.read_bytes()
        self.module.apply(self.home)
        self.assertEqual(self.settings.read_bytes(), before)
        for file in self.instructions.iterdir():
            file.write_text('')
        self.module.apply(self.home)
        restored = self.read()['providerInstances']
        self.assertEqual(restored['claudeAgent']['config'], original['providerInstances']['claudeAgent']['config'])
        if 'pi' in original['providerInstances']:
            self.assertEqual(self.module.tokenize(restored['pi']['config']['launchArgs']),
                             self.module.tokenize(original['providerInstances']['pi']['config']['launchArgs']) + ['--approve'])

    def test_pi_approval_ownership_preserves_user_arguments_and_can_be_removed(self):
        for user_approval in (False, True):
            with self.subTest(user_approval=user_approval):
                self.settings.with_name('dotfiles-launch-state.json').unlink(missing_ok=True)
                base = ['--thinking', 'low', '--session-dir', '/quoted user path'] + (['--approve'] if user_approval else [])
                self.write({'providerInstances': {'pi': {'custom': True, 'config': {'launchArgs': self.module.join_args(base)}}}})
                for _ in range(2):
                    self.module.apply(self.home)
                    provider = self.read()['providerInstances']['pi']
                    args = self.module.tokenize(provider['config']['launchArgs'])
                    self.assertEqual(args.count('--approve'), 1)
                    self.assertEqual(args[:len(base)], base)
                edited = self.read()
                edited['providerInstances']['pi']['config']['launchArgs'] += ' --user-flag "quoted edit"'
                self.write(edited)
                self.module.apply(self.home)
                self.assertEqual(self.module.tokenize(self.read()['providerInstances']['pi']['config']['launchArgs']).count('--approve'), 1)
                # Removing the declaration restores only the user's contribution.
                with patch.dict(self.module.NATIVE_CONTROLS, {'pi': []}):
                    (self.instructions / 'pi.md').write_text('')
                    self.module.apply(self.home)
                provider = self.read()['providerInstances']['pi']
                self.assertEqual(self.module.tokenize(provider['config']['launchArgs']), base + ['--user-flag', 'quoted edit'])
                self.assertTrue(provider['custom'])

    def test_unresolvable_relative_claude_file_preserves_all_existing_settings(self):
        self.write({'providerInstances': {'claudeAgent': {'config': {
            'launchArgs': '--append-system-prompt-file per-project.md'}}}})
        before = self.settings.read_bytes()
        with self.assertRaisesRegex(ValueError, 'absolute'):
            self.module.apply(self.home)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse((self.settings.parent / 'dotfiles-launch-state.json').exists())

    def test_launch_tokenizer_preserves_native_t3_quoting_semantics(self):
        arguments = ['--config', 'developer_instructions="line\\nnext"', "a'b", 'C:\\user name\\file.md', '', '$literal`']
        self.assertEqual(self.module.tokenize(self.module.join_args(arguments)), arguments)
        self.assertEqual(self.module.tokenize('--one "a\\qb" \'literal\\path\''), ['--one', 'a\\qb', 'literal\\path'])

    def test_user_edits_after_apply_survive_reconciliation_and_removal(self):
        self.write({'providerInstances': {'claudeAgent': {'config': {'launchArgs': '--disallowedTools Read'}}}})
        self.module.apply(self.home)
        edited = self.read()
        provider = edited['providerInstances']['claudeAgent']
        provider['config']['launchArgs'] += ' --enable user-feature'
        provider['environment'].append({'name': 'NEW_USER_VARIABLE', 'value': 'preserve'})
        self.write(edited)
        self.module.apply(self.home)
        (self.instructions / 'claude.md').write_text('')
        self.module.apply(self.home)
        result = self.read()['providerInstances']['claudeAgent']
        args = self.module.tokenize(result['config']['launchArgs'])
        self.assertEqual(args[:2], ['--disallowedTools', 'Read'])
        self.assertIn('--enable', args)
        self.assertIn('user-feature', args)
        self.assertIn({'name': 'NEW_USER_VARIABLE', 'value': 'preserve'}, result['environment'])

    def test_failed_settings_publication_keeps_removal_retryable(self):
        self.write({'providerInstances': {'claudeAgent': {'config': {'launchArgs': '--disallowedTools Read'}}}})
        self.module.apply(self.home)
        state_path = self.settings.with_name('dotfiles-launch-state.json')
        state_before = state_path.read_bytes()
        (self.instructions / 'claude.md').write_text('')
        publish = self.module.publish
        def fail_settings(path, document):
            if path == self.settings:
                raise OSError('Fixture settings publication failure')
            publish(path, document)
        with patch.object(self.module, 'publish', fail_settings):
            with self.assertRaises(OSError):
                self.module.apply(self.home)
        self.assertEqual(state_path.read_bytes(), state_before)
        self.module.apply(self.home)
        result = self.read()['providerInstances']['claudeAgent']
        args = self.module.tokenize(result['config']['launchArgs'])
        self.assertEqual(args[:2], ['--disallowedTools', 'Read'])
        self.assertNotIn(str(self.instructions / 'claude.md'), args)


if __name__ == '__main__':
    unittest.main()
