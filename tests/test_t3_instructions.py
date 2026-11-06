import importlib.util
import json
import os
from pathlib import Path
import tempfile
import tomllib
import unittest
from types import SimpleNamespace
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]


class T3InstructionsTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('t3_instructions', REPO / 'scripts/t3-instructions.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        scratch = tempfile.TemporaryDirectory(prefix="t3 instructions ' ")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name)
        self.settings = self.home / '.t3/userdata/settings.json'
        self.instructions = self.settings.parent / 'instructions'
        self.instructions.mkdir(parents=True)
        for name in ('codex', 'claude', 'pi'):
            (self.instructions / (name + '.md')).write_text('T3_' + name + '\nQuoted "text", apostrophe\'s.\n')

    def write(self, value):
        self.settings.write_text(json.dumps(value))

    def read(self):
        return json.loads(self.settings.read_text())

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
        self.assertEqual(self.read(), original)

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
        self.assertEqual(self.read(), original)

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
        self.assertEqual(self.module.tokenize(result['config']['launchArgs']),
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
        self.assertEqual(self.read()['providerInstances']['codex'], {'config': {'launchArgs': '--enable user-feature'}})


if __name__ == '__main__':
    unittest.main()
