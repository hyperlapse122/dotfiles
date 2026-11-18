import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import tomllib
import unittest
from types import SimpleNamespace
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
        for name in ('codex', 'claude', 'pi', 'antigravity'):
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
            self.module.apply(self.home, {}, hidden_models=[kept, added])
            self.assertEqual(json.loads(client.read_text())['providerModelPreferences']['pi'], {
                'hiddenModels': ['user-hidden', kept, 'default', added], 'modelOrder': ['custom']})

    def test_only_the_retired_managed_antigravity_adapter_is_removed(self):
        native = {'driver': 'antigravity', 'config': {'binaryPath': '/custom/runtime'}}
        self.write({'providerInstances': {'antigravity': native}})
        self.module.apply(self.home, {})
        self.assertEqual(self.read()['providerInstances']['antigravity'], {
            **native, 'environment': [{'name': 'ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE',
                'value': str(self.instructions / 'antigravity.md'), 'sensitive': False}]})
        self.write({'providerInstances': {'antigravity': {'driver': 'acpRegistry', 'config': {
            'commandPath': str(self.home / '.local/share/dotfiles/antigravity-acp/bin/antigravity-acp')}}}})
        self.module.apply(self.home, {})
        self.assertNotIn('antigravity', self.read()['providerInstances'])
        self.write({'providerInstances': {'antigravity': {'driver': 'acpRegistry', 'config': {
            'commandPath': '/custom/adapter'}}}})
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.module.apply(self.home, {})
        self.assertEqual(self.settings.read_bytes(), before)

    def test_antigravity_t3_file_selection_preserves_other_environment_and_settings(self):
        owned = 'ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE'
        unrelated = {'name': 'KEEP', 'secretRef': 'retain-reference'}
        custom = {'driver': 'antigravity', 'config': {'binaryPath': '/custom/runtime'},
                  'environment': [{'name': owned, 'value': '/owner/other.md'}]}
        self.write({'unrelated': True, 'providerInstances': {
            'antigravity': {'driver': 'antigravity', 'config': {'binaryPath': '/managed/runtime'},
                'custom': True, 'environment': [unrelated, {'name': owned, 'value': '/stale/path'},
                                               {'name': owned, 'value': '/duplicate/path'}]},
            'owner-antigravity': custom}})
        for text in ('first render', 'updated render'):
            (self.instructions / 'antigravity.md').write_text(text)
            for _ in range(2):
                self.module.apply(self.home, {})
                document = self.read()
                provider = document['providerInstances']['antigravity']
                self.assertEqual(provider, {'driver': 'antigravity', 'config': {'binaryPath': '/managed/runtime'},
                    'custom': True, 'environment': [unrelated, {'name': owned,
                        'value': str(self.instructions / 'antigravity.md'), 'sensitive': False}]})
                self.assertEqual(document['providerInstances']['owner-antigravity'], custom)
                self.assertTrue(document['unrelated'])

    def test_fresh_launches_and_claude_depth_respect_user_settings(self):
        for file in self.instructions.iterdir():
            file.write_text('')
        self.write({'providerInstances': {
            'codex': {'config': {'launchArgs': '--disable multi_agent'}},
            'claudeAgent': {'config': {'launchArgs': '--disallowedTools Read Edit'}},
            'pi': {'config': {'launchArgs': '--thinking low'}},
        }})
        self.module.apply(self.home, {'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH': '1'})
        providers = self.read()['providerInstances']
        self.assertEqual(providers['codex']['config']['launchArgs'], '--disable multi_agent')
        self.assertEqual(providers['claudeAgent']['config']['launchArgs'], '--disallowedTools Read Edit')
        self.assertEqual(providers['claudeAgent']['environment'], [
            {'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '', 'sensitive': False}])
        self.assertEqual(self.module.tokenize(providers['pi']['config']['launchArgs']), ['--thinking', 'low', '--approve'])
        providers['claudeAgent']['environment'] = [{'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '3'}]
        self.write({'providerInstances': providers})
        self.module.apply(self.home, {})
        self.assertEqual(self.read()['providerInstances']['claudeAgent']['environment'],
                         [{'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '3'}])

    def test_schema_one_migration_preserves_user_controls_and_later_duplicates(self):
        for name, base, managed, later in (
            ('codex', ['--disable', 'multi_agent'], ['--disable', 'multi_agent_v2'], ['--disable', 'multi_agent_v2']),
            ('claudeAgent', ['--disallowedTools', 'Read'], ['--disallowedTools=Read,Agent'], ['--disallowedTools=Read,Agent']),
        ):
            for edited in (False, True):
                with self.subTest(name=name, edited=edited):
                    if name == 'codex':
                        old_args = base + managed + ['-c', 'developer_instructions=' + json.dumps(
                            '<dotfiles-t3-developer-instructions>\nPrevious policy\n</dotfiles-t3-developer-instructions>')]
                    else:
                        old_args = managed + ['--append-system-prompt-file', str(self.instructions / 'claude.md')]
                    current = old_args + (later if edited else [])
                    self.write({'providerInstances': {name: {'config': {'launchArgs': self.module.join_args(current)}}}})
                    self.settings.with_name('dotfiles-launch-state.json').write_text(json.dumps({'schema': 1, 'providers': {name: {
                        'baseArgs': self.module.join_args(base), 'lastArgs': self.module.join_args(old_args), 'hadArgs': True,
                        'controlArgs': [managed], 'controlBaseArgs': base if name == 'claudeAgent' else [],
                        'baseEnvironment': [], 'lastEnvironment': [], 'hadEnvironment': False}}}))
                    self.module.apply(self.home, {})
                    args = self.module.tokenize(self.read()['providerInstances'][name]['config']['launchArgs'])
                    self.assertEqual(args[:len(base) + (len(later) if edited else 0)], base + (later if edited else []))

    def test_ambiguous_old_control_is_preserved(self):
        current = '--disallowedTools=Agent --disallowedTools=Agent'
        self.write({'providerInstances': {'claudeAgent': {'config': {'launchArgs': current}}}})
        self.settings.with_name('dotfiles-launch-state.json').write_text(json.dumps({'schema': 1, 'providers': {'claudeAgent': {
            'baseArgs': '', 'lastArgs': '--disallowedTools=Agent', 'hadArgs': False,
            'controlArgs': [['--disallowedTools=Agent']], 'controlBaseArgs': [],
            'baseEnvironment': [], 'lastEnvironment': [], 'hadEnvironment': False}}}))
        self.module.apply(self.home, {})
        args = self.module.tokenize(self.read()['providerInstances']['claudeAgent']['config']['launchArgs'])
        self.assertEqual(args.count('--disallowedTools=Agent'), 2)

    def test_existing_context_is_composed_once_and_removal_restores_user_settings(self):
        codex = self.home / '.codex'
        codex.mkdir()
        original_config = 'developer_instructions = "Existing Codex developer context"\n'
        (codex / 'config.toml').write_text(original_config)
        existing = self.home / "user's append.md"
        existing.write_text('Existing Claude file\n')
        original = {'unrelated': [1, None], 'providerInstances': {
            'codex': {'config': {'launchArgs': '--config model_reasoning_effort="low"', 'customModels': ['keep']}},
            'claudeAgent': {'config': {'launchArgs': self.module.join_args([
                '--append-system-prompt-file', str(existing), '--append-system-prompt', 'Existing Claude inline'])}},
            'pi': {'config': {'launchArgs': '--append-system-prompt relative-project.md --thinking low'}},
        }}
        self.write(original)
        self.module.apply(self.home, {})
        result = self.read()['providerInstances']
        argv = self.module.tokenize(result['codex']['config']['launchArgs'])
        developer = next(value for value in reversed(argv) if value.startswith('developer_instructions='))
        text = tomllib.loads(developer)['developer_instructions']
        self.assertIn('Existing Codex developer context', text)
        self.assertEqual(text.count('T3_codex'), 1)
        self.assertIn('Quoted "text", apostrophe\'s.', text)
        claude = self.module.tokenize(result['claudeAgent']['config']['launchArgs'])
        self.assertEqual(claude[-4:-2], ['--append-system-prompt-file', str(self.instructions / 'claude.md')])
        self.assertIn('Existing Claude file', claude[-1])
        self.assertIn('Existing Claude inline', claude[-1])
        self.assertNotIn('Existing Claude', (self.instructions / 'claude.md').read_text())
        pi = self.module.tokenize(result['pi']['config']['launchArgs'])
        self.assertEqual(pi[:4], ['--append-system-prompt', 'relative-project.md', '--thinking', 'low'])
        self.assertEqual(pi[-2:], ['--append-system-prompt', str(self.instructions / 'pi.md')])
        self.assertEqual((codex / 'config.toml').read_text(), original_config)
        before = self.settings.read_bytes()
        self.module.apply(self.home, {})
        self.assertEqual(self.settings.read_bytes(), before)
        for file in self.instructions.iterdir():
            file.write_text('')
        self.module.apply(self.home, {})
        restored = self.read()['providerInstances']
        for name in ('codex', 'claudeAgent'):
            self.assertEqual(restored[name]['config'], original['providerInstances'][name]['config'])
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
                    self.module.apply(self.home, {})
                    provider = self.read()['providerInstances']['pi']
                    args = self.module.tokenize(provider['config']['launchArgs'])
                    self.assertEqual(args.count('--approve'), 1)
                    self.assertEqual(args[:len(base)], base)
                edited = self.read()
                edited['providerInstances']['pi']['config']['launchArgs'] += ' --user-flag "quoted edit"'
                self.write(edited)
                self.module.apply(self.home, {})
                self.assertEqual(self.module.tokenize(self.read()['providerInstances']['pi']['config']['launchArgs']).count('--approve'), 1)
                # Removing the declaration restores only the user's contribution.
                with patch.dict(self.module.NATIVE_CONTROLS, {'pi': []}):
                    (self.instructions / 'pi.md').write_text('')
                    self.module.apply(self.home, {})
                provider = self.read()['providerInstances']['pi']
                self.assertEqual(self.module.tokenize(provider['config']['launchArgs']), base + ['--user-flag', 'quoted edit'])
                self.assertTrue(provider['custom'])

    def test_effective_environment_override_is_preserved_and_cannot_hide_the_addition(self):
        original = {'providerInstances': {'codex': {'config': {'launchArgs': '--config model="unused"'},
            'environment': [{'name': 'T3CODE_CODEX_LAUNCH_ARGS', 'value': '--config developer_instructions="Existing-env"', 'sensitive': False},
                            {'name': 'UNRELATED', 'secretRef': 'retain-reference'}]}}}
        self.write(original)
        self.module.apply(self.home, {'T3CODE_CODEX_LAUNCH_ARGS': '--config model="global-unused"'})
        provider = self.read()['providerInstances']['codex']
        self.assertIn('Existing-env', provider['config']['launchArgs'])
        self.assertNotIn('global-unused', provider['config']['launchArgs'])
        self.assertIn({'name': 'UNRELATED', 'secretRef': 'retain-reference'}, provider['environment'])
        self.assertEqual(next(x['value'] for x in provider['environment'] if x['name'] == 'T3CODE_CODEX_LAUNCH_ARGS'), '')
        first = self.settings.read_bytes()
        self.module.apply(self.home, {'T3CODE_CODEX_LAUNCH_ARGS': '--config model="global-unused"'})
        self.assertEqual(self.settings.read_bytes(), first)
        (self.instructions / 'codex.md').write_text('')
        self.module.apply(self.home, {})
        restored = self.read()['providerInstances']
        self.assertEqual(restored['codex'], original['providerInstances']['codex'])

    def test_unresolvable_relative_claude_file_preserves_all_existing_settings(self):
        self.write({'providerInstances': {'claudeAgent': {'config': {
            'launchArgs': '--append-system-prompt-file per-project.md'}}}})
        before = self.settings.read_bytes()
        with self.assertRaisesRegex(ValueError, 'absolute'):
            self.module.apply(self.home, {})
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertFalse((self.settings.parent / 'dotfiles-launch-state.json').exists())

    def test_launch_tokenizer_preserves_native_t3_quoting_semantics(self):
        arguments = ['--config', 'developer_instructions="line\\nnext"', "a'b", 'C:\\user name\\file.md', '', '$literal`']
        self.assertEqual(self.module.tokenize(self.module.join_args(arguments)), arguments)
        self.assertEqual(self.module.tokenize('--one "a\\qb" \'literal\\path\''), ['--one', 'a\\qb', 'literal\\path'])

    def test_user_edits_after_apply_survive_reconciliation_and_removal(self):
        self.write({'providerInstances': {'codex': {'config': {'launchArgs': '--config model="fixture"'}}}})
        self.module.apply(self.home, {})
        edited = self.read()
        provider = edited['providerInstances']['codex']
        provider['config']['launchArgs'] += ' --enable user-feature'
        provider['environment'].append({'name': 'NEW_USER_VARIABLE', 'value': 'preserve'})
        self.write(edited)
        self.module.apply(self.home, {})
        (self.instructions / 'codex.md').write_text('')
        self.module.apply(self.home, {})
        result = self.read()['providerInstances']['codex']
        self.assertEqual(self.module.tokenize(result['config']['launchArgs'])[:4],
                         ['--config', 'model=fixture', '--enable', 'user-feature'])
        self.assertEqual(result['environment'], [{'name': 'NEW_USER_VARIABLE', 'value': 'preserve'}])

    def test_environment_names_follow_native_platform_case_rules(self):
        # Patch the existing runtime platform seam; production has no test-only switch.
        for platform in ('posix', 'nt'):
            runtime = SimpleNamespace(name=platform, environ=os.environ, fdopen=os.fdopen, replace=os.replace)
            with self.subTest(platform=platform), patch.object(self.module, 'os', runtime):
                lower = [{'name': 't3code_codex_launch_args', 'value': '-c developer_instructions=lowercase'},
                         {'name': 'codex_home', 'value': str(self.home / 'custom')}]
                custom = self.home / 'custom'
                custom.mkdir(exist_ok=True)
                (custom / 'config.toml').write_text('developer_instructions="custom-home"')
                self.write({'providerInstances': {'codex': {'config': {}, 'environment': lower}}})
                (self.settings.parent / 'dotfiles-launch-state.json').unlink(missing_ok=True)
                self.module.apply(self.home, {})
                result = self.read()['providerInstances']['codex']
                self.assertEqual('lowercase' in result['config']['launchArgs'], platform == 'nt')
                self.assertEqual(lower[0] in result['environment'], platform != 'nt')

    def test_failed_settings_publication_keeps_removal_retryable(self):
        self.write({'providerInstances': {'codex': {'config': {'launchArgs': '--enable user-feature'}}}})
        self.module.apply(self.home, {})
        state_path = self.settings.with_name('dotfiles-launch-state.json')
        state_before = state_path.read_bytes()
        (self.instructions / 'codex.md').write_text('')
        publish = self.module.publish
        def fail_settings(path, document):
            if path == self.settings:
                raise OSError('Fixture settings publication failure')
            publish(path, document)
        with patch.object(self.module, 'publish', fail_settings):
            with self.assertRaises(OSError):
                self.module.apply(self.home, {})
        self.assertEqual(state_path.read_bytes(), state_before)
        self.module.apply(self.home, {})
        result = self.read()['providerInstances']['codex']
        self.assertEqual(self.module.tokenize(result['config']['launchArgs'])[:2], ['--enable', 'user-feature'])
        self.assertNotIn(self.module.CODEX_MARKER, result['config']['launchArgs'])
        self.assertNotIn('multi_agent', self.module.tokenize(result['config']['launchArgs']))


if __name__ == '__main__':
    unittest.main()
