"""Check interface:

    python tests/test_agent_settings.py

Exercises scripts/agent-settings against a seeded settings file.

The fixture starts divergent on purpose: declared keys hold values other than
the declared ones, and undeclared keys sit beside them.  A fixture that already
held the declared values would let a whole-file writer and a correct merger
produce byte-identical output, so the round could not tell them apart.  See
.compound-engineering/artifacts/solutions/best-practices/converged-fixture-state-defeats-nix-check-mutation-testing.md
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import tomlkit


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/agent-settings'
loader = importlib.machinery.SourceFileLoader('agent_settings', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
merger = importlib.util.module_from_spec(spec)
loader.exec_module(merger)

DECLARED = {
    'model': 'opus[1m]',
    'effortLevel': 'medium',
    'language': 'korean',
    'theme': 'auto',
}

# Declared keys hold other values; the rest is state only the agent writes.
EXISTING = {
    'model': 'sonnet',
    'effortLevel': 'xhigh',
    'theme': 'light',
    'themePreference': 'keep-me',
    'statusLine': {'type': 'command', 'command': 'true'},
    'enabledPlugins': {'example@marketplace': True},
    'numStartups': 41,
}


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'home'
        self.settings = self.home / '.claude/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(DECLARED)

    def declare(self, assign, remove=None):
        self.declared.write_text(json.dumps({'set': assign, 'remove': remove or []}))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def test_declared_keys_reassert_and_undeclared_keys_survive(self):
        self.seed()
        self.merge()
        result = self.read()
        for key, value in DECLARED.items():
            self.assertEqual(result[key], value)
        for key in ['themePreference', 'statusLine', 'enabledPlugins', 'numStartups']:
            self.assertEqual(result[key], EXISTING[key])

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual(before.st_ino, after.st_ino)
        self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)

    def test_creates_file_and_private_parent_when_absent(self):
        self.merge()
        self.assertEqual(self.read(), DECLARED)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.settings.parent.stat().st_mode & 0o777, 0o700)

    def test_an_empty_file_merges_as_an_empty_object(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('')
        self.merge()
        self.assertEqual(self.read(), DECLARED)

    def test_refuses_a_symlinked_settings_path(self):
        self.settings.parent.mkdir(parents=True)
        target = Path(self.tmp.name) / 'elsewhere.json'
        target.write_text(json.dumps({'model': 'untouched'}))
        self.settings.symlink_to(target)
        with self.assertRaises(ValueError):
            self.merge()
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(json.loads(target.read_text()), {'model': 'untouched'})

    def test_refuses_a_symlinked_parent_directory(self):
        elsewhere = Path(self.tmp.name) / 'elsewhere'
        elsewhere.mkdir()
        self.home.mkdir()
        self.settings.parent.symlink_to(elsewhere)
        with self.assertRaises(ValueError):
            self.merge()

    def test_refuses_malformed_json_without_touching_the_file(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('{ not json')
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_text(), '{ not json')

    def test_refuses_settings_that_are_valid_json_but_not_an_object(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('[]')
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_text(), '[]')

    def test_refuses_declared_settings_that_are_not_an_object(self):
        self.seed()
        self.declared.write_text('["model"]')
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.read(), EXISTING)

    def test_refuses_an_object_valued_declaration(self):
        # Assignment is one level deep, so declaring an object would replace
        # the user's whole object rather than merging into it.
        self.seed()
        self.declare({'permissions': {'allow': ['Bash']}})
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.read(), EXISTING)

    def test_refuses_a_remove_list_that_is_not_names(self):
        self.seed()
        self.declare(DECLARED, remove=[{'model': True}])
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.read(), EXISTING)

    def test_refuses_a_key_declared_as_both_set_and_removed(self):
        self.seed()
        self.declare(DECLARED, remove=['model'])
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.read(), EXISTING)

    def test_retired_key_is_dropped_and_others_survive(self):
        self.seed()
        self.declare(DECLARED, remove=['themePreference'])
        self.merge()
        result = self.read()
        self.assertNotIn('themePreference', result)
        self.assertEqual(result['numStartups'], EXISTING['numStartups'])
        self.assertEqual(result['model'], DECLARED['model'])

    def test_retiring_an_absent_key_is_a_no_op(self):
        self.seed()
        self.merge()
        before = self.settings.stat().st_mtime_ns
        self.declare(DECLARED, remove=['neverPresent'])
        self.merge()
        self.assertEqual(self.settings.stat().st_mtime_ns, before)

    def test_preserves_a_write_that_lands_while_merging(self):
        # The file has another writer. A plain read-modify-write would discard
        # whatever the agent wrote between the read and the replace.
        self.seed()
        original = merger.read_settings

        calls = []

        def read_then_interfere(path):
            current = original(path)
            calls.append(None)
            # Interfere on the merge loop's first read, not the validation
            # read that precedes it, so this exercises the compare-and-swap.
            if len(calls) == 2:
                concurrent = dict(current)
                concurrent['writtenByTheAgent'] = 'keep me'
                path.write_text(json.dumps(concurrent))
            return current

        with mock.patch.object(merger, 'read_settings', read_then_interfere):
            self.merge()
        result = self.read()
        self.assertEqual(result['writtenByTheAgent'], 'keep me')
        self.assertEqual(result['model'], DECLARED['model'])

    def test_gives_up_when_the_file_never_settles(self):
        self.seed()
        original = merger.read_settings

        def read_then_interfere(path):
            current = original(path)
            churn = dict(current)
            churn['churn'] = os.urandom(4).hex()
            path.write_text(json.dumps(churn))
            return current

        with mock.patch.object(merger, 'read_settings', read_then_interfere):
            with self.assertRaises(ValueError):
                self.merge()

    def test_keeps_non_ascii_text_as_written(self):
        # The interface language here is Korean, so non-ASCII in an undeclared
        # value is expected. ensure_ascii would rewrite it to \uXXXX escapes on
        # every activation, and a locale-dependent read could fail outright.
        self.seed(dict(EXISTING, koreanNote='한글 설정'))
        self.merge()
        raw = self.settings.read_text(encoding='utf-8')
        self.assertIn('한글 설정', raw)
        self.assertNotIn('\\ud55c', raw)

    def test_survives_the_file_disappearing_after_the_snapshot(self):
        self.seed(dict(DECLARED))
        original = merger.read_settings

        def read_then_delete(path):
            current = original(path)
            if not getattr(read_then_delete, 'fired', False):
                read_then_delete.fired = True
                path.unlink()
            return current

        with mock.patch.object(merger, 'read_settings', read_then_delete):
            self.merge()
        self.assertEqual(self.read(), DECLARED)

    def test_refusal_does_not_create_or_tighten_the_parent(self):
        # A refusal must leave the disk as it found it, including the parent.
        self.settings.parent.mkdir(parents=True)
        self.settings.parent.chmod(0o755)
        self.settings.write_text('{ not json')
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.parent.stat().st_mode & 0o777, 0o755)

    def test_tightens_an_existing_loose_parent_directory(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.parent.chmod(0o755)
        self.seed()
        self.merge()
        self.assertEqual(self.settings.parent.stat().st_mode & 0o777, 0o700)

    def test_removes_the_temporary_file_when_the_replace_fails(self):
        self.seed()
        with mock.patch.object(merger.os, 'replace', side_effect=OSError('nope')):
            with self.assertRaises(OSError):
                self.merge()
        # The persistent lock must survive; staged settings must not.
        leftovers = [p.name for p in self.settings.parent.iterdir()
                     if p.name not in ('settings.json', '.settings.json.lock')]
        self.assertEqual(leftovers, [])
        self.assertEqual(self.read(), EXISTING)

    def test_restores_a_declared_key_the_user_removed(self):
        self.seed({'numStartups': 41})
        self.merge()
        result = self.read()
        self.assertEqual(result['model'], 'opus[1m]')
        self.assertEqual(result['numStartups'], 41)

    def test_leaves_no_temporary_file_behind(self):
        self.seed()
        self.merge()
        leftovers = [p.name for p in self.settings.parent.iterdir()
                     if p.name not in ('settings.json', '.settings.json.lock')]
        self.assertEqual(leftovers, [])

    def test_refusal_names_the_agent_the_caller_labelled(self):
        # Two agents share this merger, so a failure in the rebuild log has to
        # say which file it was about.
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('{ not json')
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--label', 'Antigravity CLI',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Antigravity CLI settings merge failed', result.stderr)

    def run_script(self):
        # Importing the module skips `if __name__ == '__main__': sys.exit(main())`
        # entirely, so the link between a refusal and a non-zero process status
        # is only observable by running the script the way activation does.
        return subprocess.run(
            [sys.executable, str(SCRIPT),
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)

    def test_process_exits_zero_and_merges_on_success(self):
        self.seed()
        result = self.run_script()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.read()['model'], 'opus[1m]')

    def test_process_exits_non_zero_and_names_the_path_on_refusal(self):
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text('{ not json')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.settings), result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(self.settings.read_text(), '{ not json')

    def test_refuses_to_run_as_root(self):
        # Patch the euid rather than reading the ambient one: a test that only
        # asserts the non-root path can never go red for a removed guard.
        self.seed()
        with mock.patch.object(merger.os, 'geteuid', return_value=0):
            with self.assertRaises(SystemExit) as raised:
                merger.main(['--settings', str(self.settings),
                             '--declared', str(self.declared)])
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(self.read(), EXISTING)



# Tokscale nests preferences one level down, beside runtime state it writes
# itself.  Every nested object below already carries siblings the declaration
# does not name, and the declared leaves start at other values, so a merger that
# replaced the whole object would lose a key rather than coincide with the fix.
NESTED_EXISTING = {
    'colorPalette': 'green',
    'scanner': {'opencodeDbPaths': ['x'], 'bucketTimezone': 'UTC'},
    'autosubmit': {'enabled': True, 'lastRunAtMs': 1700000000000, 'lastError': 'timeout'},
    'scanner.bucketTimezone': 'literal top-level key',
    'usage': {'daily': [1, 2, 3]},
}

NESTED_PATHS = [
    {'path': ['scanner', 'bucketTimezone'], 'value': 'Asia/Seoul'},
    {'path': ['autosubmit', 'enabled'], 'value': False},
]


class NestedPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.config/tokscale/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(NESTED_PATHS, assign={'colorPalette': 'blue'})

    def declare(self, paths, assign=None, remove=None):
        self.declared.write_text(json.dumps(
            {'set': assign or {}, 'remove': remove or [], 'setPaths': paths}))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else NESTED_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def assert_refused_untouched(self, *needles):
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError) as raised:
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)
        for needle in needles:
            self.assertIn(needle, str(raised.exception))

    def test_nested_leaf_reasserts_and_its_siblings_survive(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertEqual(result['scanner'], {'opencodeDbPaths': ['x'], 'bucketTimezone': 'Asia/Seoul'})
        self.assertEqual(result['colorPalette'], 'blue')
        self.assertEqual(result['usage'], NESTED_EXISTING['usage'])

    def test_missing_intermediate_object_is_created_with_only_the_leaf(self):
        self.seed({'colorPalette': 'green'})
        self.declare([{'path': ['autosubmit', 'enabled'], 'value': False}])
        self.merge()
        self.assertEqual(self.read(), {'colorPalette': 'green', 'autosubmit': {'enabled': False}})

    def test_runtime_state_beside_a_reasserted_leaf_survives(self):
        self.seed()
        self.merge()
        self.assertEqual(self.read()['autosubmit'],
                         {'enabled': False, 'lastRunAtMs': 1700000000000, 'lastError': 'timeout'})

    def test_creates_the_file_when_absent(self):
        self.merge()
        self.assertEqual(self.read(), {
            'colorPalette': 'blue',
            'scanner': {'bucketTimezone': 'Asia/Seoul'},
            'autosubmit': {'enabled': False},
        })

    def test_refuses_a_non_object_intermediate_and_names_the_path(self):
        self.seed(dict(NESTED_EXISTING, scanner='flat'))
        self.assert_refused_untouched('["scanner", "bucketTimezone"]')

    def test_refuses_a_null_intermediate(self):
        # null is not an object either; replacing it would discard a value
        # the owner wrote on purpose.
        self.seed(dict(NESTED_EXISTING, scanner=None))
        self.assert_refused_untouched('["scanner", "bucketTimezone"]')

    def test_non_object_intermediate_refusal_does_not_tighten_the_parent(self):
        self.seed(dict(NESTED_EXISTING, scanner='flat'))
        self.settings.parent.chmod(0o755)
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.parent.stat().st_mode & 0o777, 0o755)

    def test_a_dotted_top_level_key_is_neither_read_nor_written(self):
        self.seed()
        self.merge()
        self.assertEqual(self.read()['scanner.bucketTimezone'], 'literal top-level key')
        # A literal dotted key is also not taken as the object to merge into.
        self.seed({'scanner.bucketTimezone': 'UTC'})
        self.merge()
        result = self.read()
        self.assertEqual(result['scanner.bucketTimezone'], 'UTC')
        self.assertEqual(result['scanner'], {'bucketTimezone': 'Asia/Seoul'})

    def test_a_segment_containing_a_dot_is_one_key(self):
        self.seed({'a': {'b': 1}})
        self.declare([{'path': ['a.b', 'c'], 'value': 2}])
        self.merge()
        self.assertEqual(self.read(), {'a': {'b': 1}, 'a.b': {'c': 2}})

    def test_deeper_paths_merge_at_every_level(self):
        self.seed({'a': {'keep': 1, 'b': {'keep': 2, 'c': 'old'}}})
        self.declare([{'path': ['a', 'b', 'c'], 'value': 'new'}])
        self.merge()
        self.assertEqual(self.read(), {'a': {'keep': 1, 'b': {'keep': 2, 'c': 'new'}}})

    def test_refuses_object_and_list_values(self):
        self.seed()
        for value in ({'bucketTimezone': 'Asia/Seoul'}, ['Asia/Seoul']):
            with self.subTest(value=value):
                self.declare([{'path': ['scanner'], 'value': value}])
                self.assert_refused_untouched('["scanner"]')

    def test_refuses_malformed_path_entries(self):
        self.seed()
        cases = [
            'not a list',
            ['not an entry'],
            [{'path': [], 'value': 1}],
            [{'path': 'scanner.bucketTimezone', 'value': 1}],
            [{'path': ['scanner', 3], 'value': 1}],
            [{'path': ['scanner', 'bucketTimezone']}],
            [{'path': ['scanner', 'bucketTimezone'], 'value': 1, 'extra': True}],
        ]
        for paths in cases:
            with self.subTest(paths=paths):
                self.declare(paths)
                self.assert_refused_untouched()

    def test_refuses_a_path_whose_first_key_is_set_flat(self):
        self.seed()
        self.declare(NESTED_PATHS, assign={'scanner': 'x'})
        self.assert_refused_untouched('scanner')

    def test_refuses_a_path_whose_first_key_is_removed(self):
        self.seed()
        self.declare(NESTED_PATHS, remove=['autosubmit'])
        self.assert_refused_untouched('autosubmit')

    def test_refuses_overlapping_paths(self):
        # One path running through another's leaf would either replace a
        # declared scalar with an object or be refused only at run time,
        # depending on the order they happened to be listed in.
        self.seed()
        for paths in ([{'path': ['a'], 'value': 1}, {'path': ['a', 'b'], 'value': 2}],
                      [{'path': ['a', 'b'], 'value': 2}, {'path': ['a'], 'value': 1}],
                      [{'path': ['a', 'b'], 'value': 1}, {'path': ['a', 'b'], 'value': 2}]):
            with self.subTest(paths=paths):
                self.declare(paths)
                self.assert_refused_untouched('["a"')

    def test_refuses_an_unknown_declared_field(self):
        # A misspelt field would otherwise be ignored and its values never
        # asserted, with nothing in the rebuild log to say so.
        self.seed()
        self.declared.write_text(json.dumps({'set': {}, 'setPath': NESTED_PATHS}))
        self.assert_refused_untouched('setPath')

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual(before.st_ino, after.st_ino)
        self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)

    def test_preserves_a_nested_write_that_lands_while_merging(self):
        self.seed()
        original = merger.read_settings
        calls = []

        def read_then_interfere(path):
            current = original(path)
            calls.append(None)
            # The merge loop's first read, after the validation read.
            if len(calls) == 2:
                concurrent = json.loads(json.dumps(current))
                concurrent['scanner']['writtenByTokscale'] = 'keep me'
                path.write_text(json.dumps(concurrent))
            return current

        with mock.patch.object(merger, 'read_settings', read_then_interfere):
            self.merge()
        self.assertEqual(self.read()['scanner'], {
            'opencodeDbPaths': ['x'],
            'bucketTimezone': 'Asia/Seoul',
            'writtenByTokscale': 'keep me',
        })

    def test_does_not_mutate_the_read_document(self):
        # The unchanged check compares the merge against what was read; a merge
        # that edited the read objects in place would always compare equal and
        # never write.
        current = json.loads(json.dumps(NESTED_EXISTING))
        merger.apply(current, {}, [], [(['scanner', 'bucketTimezone'], 'Asia/Seoul')])
        self.assertEqual(current, NESTED_EXISTING)

    def test_flat_declarations_behave_as_before(self):
        # The Gemini declaration carries no setPaths and the Claude global-config
        # one an empty list; both forms must produce the same bytes.
        outputs = []
        for extra in ({}, {'setPaths': []}):
            self.seed(EXISTING)
            self.declared.write_text(json.dumps(dict({'set': DECLARED, 'remove': ['numStartups']}, **extra)))
            self.merge()
            outputs.append(self.settings.read_bytes())
        self.assertEqual(outputs[0], outputs[1])
        result = json.loads(outputs[0])
        self.assertEqual(result, dict({k: v for k, v in EXISTING.items() if k != 'numStartups'}, **DECLARED))

    def test_process_merges_nested_paths(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--label', 'Tokscale',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['scanner']['bucketTimezone'], 'Asia/Seoul')

    def test_process_reports_a_non_object_intermediate(self):
        self.seed(dict(NESTED_EXISTING, scanner='flat'))
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--label', 'Tokscale',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Tokscale settings merge failed', result.stderr)
        self.assertIn('scanner', result.stderr)


# A hooks.json-shaped file maps a hook name to its events. Another writer
# owns `foreign-status` and rewrites it at run time; the declaration owns
# `repo-owned`, seeded here with a stale value so a merger that skipped the
# key could not match by accident.
OWNED = {
    'repo-owned': {
        'enabled': True,
        'SessionStart': [{'type': 'command', 'command': '/nix/store/new --harness antigravity', 'timeout': 10}],
    },
}

OWNED_EXISTING = {
    'foreign-status': {
        'enabled': True,
        'PreInvocation': [{'type': 'command', 'command': 'foreign-hook pre', 'timeout': 10}],
        'Stop': [{'type': 'command', 'command': 'foreign-hook stop', 'timeout': 10}],
    },
    'repo-owned': {
        'enabled': False,
        'SessionStart': [{'type': 'command', 'command': '/nix/store/old', 'timeout': 99}],
        'Stop': [{'type': 'command', 'command': 'stale', 'timeout': 1}],
    },
}


class OwnedKeyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.gemini/config/hooks.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare()

    def declare(self, own=None, **fields):
        document = {'own': OWNED if own is None else own}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else OWNED_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def assert_refused_untouched(self, *needles):
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError) as raised:
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)
        for needle in needles:
            self.assertIn(needle, str(raised.exception))

    def test_owned_key_is_replaced_whole_and_other_keys_survive(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertEqual(result['repo-owned'], OWNED['repo-owned'])
        self.assertEqual(result['foreign-status'], OWNED_EXISTING['foreign-status'])
        self.assertEqual(sorted(result), ['foreign-status', 'repo-owned'])

    def test_creates_the_file_with_only_the_owned_key(self):
        self.merge()
        self.assertEqual(self.read(), OWNED)

    def test_owned_model_selections_drop_an_effort_an_earlier_generation_wrote(self):
        # T3 Code's settings.json owns both Claude selections with no options,
        # so the effort option an earlier rebuild wrote must not survive.
        stale = {'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5',
                 'options': [{'id': 'effort', 'value': 'xhigh'}]}
        self.seed({
            'defaultModelSelection': stale,
            'textGenerationModelSelection': {**stale, 'model': 'claude-haiku-5-5'},
            'fontSize': 14,
        })
        self.declare(own={
            'defaultModelSelection': {
                'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5', 'options': []},
            'textGenerationModelSelection': {
                'instanceId': 'claudeAgent', 'model': 'claude-haiku-5-5', 'options': []},
        })
        self.merge()
        result = self.read()
        for key in ('defaultModelSelection', 'textGenerationModelSelection'):
            self.assertEqual(result[key]['options'], [], key)
            self.assertNotIn('effort', json.dumps(result[key]), key)
        self.assertEqual(result['fontSize'], 14)

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = os.stat(self.settings)
        self.merge()
        after = os.stat(self.settings)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_owned_value_is_not_aliased_to_the_declaration(self):
        assign, retire, paths, _, owned, upserts, *_ = merger.declaration(self.declared)
        merged = merger.apply({}, assign, retire, paths, owned, upserts)
        merged['repo-owned']['enabled'] = False
        self.assertTrue(owned['repo-owned']['enabled'])

    def test_refuses_a_key_both_owned_and_set(self):
        self.seed()
        self.declare(set={'repo-owned': 'flat'})
        self.assert_refused_untouched('repo-owned')

    def test_refuses_a_key_both_owned_and_removed(self):
        self.seed()
        self.declare(remove=['repo-owned'])
        self.assert_refused_untouched('repo-owned')

    def test_refuses_a_path_through_an_owned_key(self):
        self.seed()
        self.declare(setPaths=[{'path': ['repo-owned', 'enabled'], 'value': True}])
        self.assert_refused_untouched('repo-owned')

    def test_refuses_an_own_field_that_is_not_an_object(self):
        self.seed()
        self.declare(own=['repo-owned'])
        self.assert_refused_untouched('own')

    def test_process_merges_owned_keys(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--label', 'Antigravity hooks',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['repo-owned'], OWNED['repo-owned'])
        self.assertEqual(self.read()['foreign-status'], OWNED_EXISTING['foreign-status'])


# Codex keeps config.toml, which it and `codex plugin add` both rewrite, and
# the user edits by hand.  Every declared key starts at the opposite value, and
# the comments and tables the declaration does not name are the bytes a
# re-serializing merger would lose.
TOML_EXISTING = '''\
# Written by hand; keep this comment.
model = "gpt-5.1-codex" # the user's model
check_for_update_on_startup = true # turned back on by hand
developer_instructions = "stale text from an earlier generation"

[features]
in_app_updates = true
memories = true
web_search = true # unowned sibling

# Installed by codex plugin add.
[plugins."x"]
enabled = true

[marketplaces.y]
source = "https://example.invalid/y.git"

[projects."/home/h82/src"]
trust_level = "trusted"
'''

TOML_DECLARED = {
    'set': {'check_for_update_on_startup': False},
    'remove': ['developer_instructions'],
    'setPaths': [
        {'path': ['features', 'in_app_updates'], 'value': False},
        {'path': ['features', 'daemon_auto_start'], 'value': False},
        {'path': ['features', 'memories'], 'value': False},
    ],
}

TOML_MERGED = {
    'check_for_update_on_startup': False,
    'features': {'in_app_updates': False, 'daemon_auto_start': False, 'memories': False},
}


class TomlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.codex/config.toml'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(TOML_DECLARED)

    def declare(self, document):
        self.declared.write_text(json.dumps(document))

    def seed(self, text=TOML_EXISTING):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(text)
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared, fmt='toml')

    def read(self):
        return tomlkit.parse(self.settings.read_text()).unwrap()

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--format', 'toml', '--label', 'Codex',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)

    def test_declared_keys_reassert_and_user_text_survives(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertFalse(result['check_for_update_on_startup'])
        self.assertEqual(result['features'], {
            'in_app_updates': False, 'memories': False, 'daemon_auto_start': False, 'web_search': True})
        self.assertEqual(result['model'], 'gpt-5.1-codex')
        text = self.settings.read_text()
        # tomlkit files a comment above a table header under the table before
        # it, so a leaf added to [features] lands after that comment.  Its
        # bytes survive; only its neighbour changes, and only on the run that
        # adds the leaf.
        for unowned in [
            '# Written by hand; keep this comment.\n',
            'model = "gpt-5.1-codex" # the user\'s model\n',
            'check_for_update_on_startup = false # turned back on by hand\n',
            'web_search = true # unowned sibling\n',
            '# Installed by codex plugin add.\n',
            '[plugins."x"]\nenabled = true\n',
            '[marketplaces.y]\nsource = "https://example.invalid/y.git"\n',
            '[projects."/home/h82/src"]\ntrust_level = "trusted"\n',
        ]:
            self.assertIn(unowned, text)

    def test_creates_the_file_with_only_the_declared_keys(self):
        self.merge()
        self.assertEqual(self.read(), TOML_MERGED)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_process_refuses_malformed_toml_and_names_the_file(self):
        self.seed('model = "unterminated\n')
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Codex settings merge failed', result.stderr)
        self.assertIn(str(self.settings), result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(self.settings.read_text(), 'model = "unterminated\n')

    def test_refuses_null_before_touching_the_file(self):
        # TOML has no null, so a declared null cannot be written; refusing it
        # during validation keeps the refusal from leaving a half-made file.
        self.seed()
        self.settings.parent.chmod(0o755)
        for document in (
            {'set': {'check_for_update_on_startup': None}},
            {'setPaths': [{'path': ['features', 'memories'], 'value': None}]},
            {'own': {'mcp_servers': {'x': {'command': None}}}},
            {'ownEntries': [{'path': ['env'], 'key': 'name', 'entries': [{'name': 'x', 'value': None}]}]},
        ):
            with self.subTest(document=document):
                self.declare(document)
                with self.assertRaises(ValueError) as raised:
                    self.merge()
                self.assertIn('null', str(raised.exception))
                self.assertEqual(self.settings.read_text(), TOML_EXISTING)
                self.assertEqual(self.settings.parent.stat().st_mode & 0o777, 0o755)

    def test_null_stays_allowed_in_json(self):
        self.declare({'set': {'model': None}})
        merger.merge(self.settings.with_suffix('.json'), self.declared)
        self.assertEqual(json.loads(self.settings.with_suffix('.json').read_text()), {'model': None})

    def test_remove_drops_a_top_level_key_and_keeps_sibling_tables(self):
        self.seed()
        self.declare(dict(TOML_DECLARED, remove=['model', 'developer_instructions']))
        self.merge()
        result = self.read()
        self.assertNotIn('model', result)
        self.assertNotIn('developer_instructions', result)
        self.assertEqual(result['plugins'], {'x': {'enabled': True}})
        self.assertEqual(result['marketplaces'], {'y': {'source': 'https://example.invalid/y.git'}})
        self.assertEqual(result['projects'], {'/home/h82/src': {'trust_level': 'trusted'}})

    def test_the_retired_developer_instructions_key_goes(self):
        self.seed()
        self.merge()
        self.assertNotIn('developer_instructions', self.read())
        self.assertNotIn('stale text', self.settings.read_text())

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_does_not_mutate_the_read_document(self):
        current = tomlkit.parse(TOML_EXISTING)
        assign, retire, paths, _, owned, upserts, *_ = merger.declaration(self.declared, fmt='toml')
        merger.apply(current, assign, retire, paths, owned, upserts)
        self.assertEqual(tomlkit.dumps(current), TOML_EXISTING)

    def test_process_merges_toml(self):
        self.seed()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['features']['daemon_auto_start'], False)
        self.assertIn('# Written by hand; keep this comment.\n', self.settings.read_text())

    def test_multi_line_string_reads_back_byte_identical(self):
        text = 'First line.\nIt\'s said "quoted" and C:\\path\\n stays literal.\n\nLast line.\n'
        self.seed()
        self.declare({'set': {'instructions_text': text}})
        self.merge()
        result = self.read()
        self.assertEqual(result['instructions_text'], text)
        self.assertEqual(result['model'], 'gpt-5.1-codex')
        self.assertEqual(result['features']['web_search'], True)
        self.assertIn('model = "gpt-5.1-codex" # the user\'s model\n', self.settings.read_text())

    def test_upsert_appends_to_an_inline_list_of_tables(self):
        self.seed('env = [{ name = "FOO", value = "1" }]\n')
        self.declare({'upsertPaths': [
            {'path': ['env'], 'key': 'name', 'value': {'name': 'BAR', 'value': '1'}}]})
        self.merge()
        self.assertEqual(self.read()['env'], [
            {'name': 'FOO', 'value': '1'}, {'name': 'BAR', 'value': '1'}])

    def test_refuses_a_null_inside_an_upsert_value(self):
        self.seed()
        self.declare({'upsertPaths': [
            {'path': ['env'], 'key': 'name', 'value': {'name': 'BAR', 'value': None}}]})
        with self.assertRaises(ValueError) as raised:
            self.merge()
        self.assertIn('null', str(raised.exception))
        self.assertEqual(self.settings.read_text(), TOML_EXISTING)

    def test_process_rejects_an_unknown_format(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--format', 'yaml', '--label', 'Codex',
             '--settings', str(self.settings), '--declared', str(self.declared)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('--format', result.stderr)


UPSERT_ENV = ['providerInstances', 'claudeAgent', 'environment']
UPSERT_ENTRY = {'name': 'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD', 'value': '1'}

UPSERT_EXISTING = {
    'providerInstances': {
        'claudeAgent': {
            'driver': 'claudeAgent',
            'config': {'launchArgs': '--keep'},
            'environment': [{'name': 'FOO', 'value': '1'}],
        },
        'codex': {'driver': 'codex', 'environment': [{'name': 'X', 'value': 'y'}]},
    },
    'other': 1,
}


class UpsertPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.t3/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(UPSERT_ENTRY)

    def declare(self, value, path=UPSERT_ENV, **fields):
        document = {'upsertPaths': [{'path': path, 'key': 'name', 'value': value}]}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else UPSERT_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def environment(self):
        return self.read()['providerInstances']['claudeAgent']['environment']

    def test_appends_and_keeps_the_user_entry(self):
        self.seed()
        self.merge()
        self.assertEqual(self.environment(), [{'name': 'FOO', 'value': '1'}, UPSERT_ENTRY])

    def test_second_run_adds_no_duplicate_and_does_not_rewrite(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual(len(self.environment()), 2)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_replaces_the_entry_with_the_same_name(self):
        data = json.loads(json.dumps(UPSERT_EXISTING))
        data['providerInstances']['claudeAgent']['environment'].insert(
            0, {'name': UPSERT_ENTRY['name'], 'value': '0'})
        data['providerInstances']['claudeAgent']['environment'].append(
            {'name': UPSERT_ENTRY['name'], 'value': 'later duplicate'})
        self.seed(data)
        self.merge()
        self.assertEqual(self.environment(), [UPSERT_ENTRY, {'name': 'FOO', 'value': '1'}])

    def test_creates_the_path_when_absent(self):
        self.merge()
        self.assertEqual(self.read(), {
            'providerInstances': {'claudeAgent': {'environment': [UPSERT_ENTRY]}}})

    def test_creates_the_list_when_the_parent_exists_without_it(self):
        self.seed({'providerInstances': {'claudeAgent': {'driver': 'claudeAgent'}}})
        self.merge()
        self.assertEqual(self.read()['providerInstances']['claudeAgent'], {
            'driver': 'claudeAgent', 'environment': [UPSERT_ENTRY]})

    def test_siblings_and_other_instances_are_untouched(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertEqual(result['providerInstances']['claudeAgent']['config'], {'launchArgs': '--keep'})
        self.assertEqual(result['providerInstances']['codex'], UPSERT_EXISTING['providerInstances']['codex'])
        self.assertEqual(result['other'], 1)

    def test_setpaths_still_refuses_a_non_scalar_value(self):
        self.seed()
        self.declared.write_text(json.dumps(
            {'setPaths': [{'path': UPSERT_ENV, 'value': [UPSERT_ENTRY]}]}))
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_does_not_mutate_the_read_document(self):
        current = json.loads(json.dumps(UPSERT_EXISTING))
        merger.apply(current, {}, [], [], {}, [(UPSERT_ENV, 'name', UPSERT_ENTRY)])
        self.assertEqual(current, UPSERT_EXISTING)

    def test_collapses_later_duplicates_so_the_declared_value_wins(self):
        # The app applies entries in order and the last wins, so a later
        # duplicate holding 0 would turn the declared variable off.
        data = json.loads(json.dumps(UPSERT_EXISTING))
        data['providerInstances']['claudeAgent']['environment'] = [
            {'name': UPSERT_ENTRY['name'], 'value': '1'},
            {'name': 'FOO', 'value': '1'},
            {'name': UPSERT_ENTRY['name'], 'value': '0'},
        ]
        self.seed(data)
        self.merge()
        self.assertEqual(self.environment(), [UPSERT_ENTRY, {'name': 'FOO', 'value': '1'}])
        self.merge()
        self.assertEqual(self.environment(), [UPSERT_ENTRY, {'name': 'FOO', 'value': '1'}])

    def assert_refused(self, document):
        self.seed()
        self.declared.write_text(json.dumps(document))
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_refuses_malformed_upsert_declarations(self):
        entry = {'path': UPSERT_ENV, 'key': 'name', 'value': UPSERT_ENTRY}
        for document in (
            {'upsertPaths': entry},
            {'upsertPaths': [{'path': UPSERT_ENV, 'value': UPSERT_ENTRY}]},
            {'upsertPaths': [dict(entry, extra=1)]},
            {'upsertPaths': [dict(entry, path=[])]},
            {'upsertPaths': [dict(entry, path='providerInstances')]},
            {'upsertPaths': [dict(entry, key=1)]},
            {'upsertPaths': [dict(entry, value=['name'])]},
            {'upsertPaths': [dict(entry, value={'value': '1'})]},
        ):
            with self.subTest(document=document):
                self.assert_refused(document)

    def test_refuses_an_upsert_on_a_key_set_removed_or_owned(self):
        entry = {'path': UPSERT_ENV, 'key': 'name', 'value': UPSERT_ENTRY}
        for field in ({'set': {'providerInstances': 1}},
                      {'remove': ['providerInstances']},
                      {'own': {'providerInstances': {}}}):
            with self.subTest(field=field):
                self.assert_refused(dict(field, upsertPaths=[entry]))

    def test_refuses_an_upsert_overlapping_a_set_path(self):
        self.assert_refused({
            'setPaths': [{'path': UPSERT_ENV + ['x'], 'value': 1}],
            'upsertPaths': [{'path': UPSERT_ENV, 'key': 'name', 'value': UPSERT_ENTRY}],
        })

    def test_refuses_overlapping_or_repeated_upserts(self):
        entry = {'path': UPSERT_ENV, 'key': 'name', 'value': UPSERT_ENTRY}
        for second in (
            dict(entry, value=dict(UPSERT_ENTRY, value='0')),
            dict(entry, path=UPSERT_ENV[:2]),
            dict(entry, path=UPSERT_ENV + ['inner']),
            dict(entry, key='value', value=UPSERT_ENTRY),
        ):
            with self.subTest(second=second):
                self.assert_refused({'upsertPaths': [entry, second]})

    def test_two_upserts_may_name_different_entries_of_one_list(self):
        other = {'name': 'OTHER', 'value': '2'}
        self.seed()
        self.declared.write_text(json.dumps({'upsertPaths': [
            {'path': UPSERT_ENV, 'key': 'name', 'value': UPSERT_ENTRY},
            {'path': UPSERT_ENV, 'key': 'name', 'value': other},
        ]}))
        self.merge()
        self.assertEqual(self.environment(), [{'name': 'FOO', 'value': '1'}, UPSERT_ENTRY, other])

    def test_refuses_an_existing_value_that_is_not_a_list(self):
        for environment in ({'name': 'FOO'}, 'FOO'):
            data = json.loads(json.dumps(UPSERT_EXISTING))
            data['providerInstances']['claudeAgent']['environment'] = environment
            with self.subTest(environment=environment):
                self.seed(data)
                before = self.settings.read_bytes()
                with self.assertRaises(ValueError):
                    self.merge()
                self.assertEqual(self.settings.read_bytes(), before)


MIGRATE = {'from': 'providers', 'to': 'providerInstances',
           'kinds': ['antigravity', 'claudeAgent', 'codex']}


class MigrateInstanceTests(unittest.TestCase):
    """The retired providers block moves into providerInstances as T3 Code would."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.t3/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        # The declaration home/h82/t3code.nix renders: the migration plus
        # leaves that create the instances the migration must not lose.
        self.declared.write_text(json.dumps({
            'migrateInstances': MIGRATE,
            'setPaths': [
                {'path': ['providerInstances', 'claudeAgent', 'driver'], 'value': 'claudeAgent'},
                {'path': ['providerInstances', 'claudeAgent', 'config', 'launchArgs'], 'value': '--add-dir x'},
                {'path': ['providerInstances', 'antigravity', 'enabled'], 'value': True},
            ],
        }))

    def seed(self, data):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data, indent=2))

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def test_legacy_fields_survive_beside_the_declared_leaves(self):
        self.seed({'providers': {
            'claudeAgent': {'enabled': True, 'binaryPath': '/opt/claude', 'homePath': '/h'},
            'antigravity': {'enabled': False},
        }})
        self.merge()
        self.assertEqual(self.read(), {'providerInstances': {
            'claudeAgent': {'driver': 'claudeAgent', 'enabled': True,
                            'config': {'binaryPath': '/opt/claude', 'homePath': '/h',
                                       'launchArgs': '--add-dir x'}},
            'antigravity': {'driver': 'antigravity', 'enabled': True, 'config': {}},
        }})

    def test_kinds_not_listed_stay_for_t3_code_to_migrate(self):
        self.seed({'providers': {'cursor': {'enabled': True, 'binaryPath': '/c'},
                                 'codex': {'binaryPath': '/x'}}})
        self.merge()
        result = self.read()
        self.assertEqual(result['providers'], {'cursor': {'enabled': True, 'binaryPath': '/c'}})
        self.assertEqual(result['providerInstances']['codex'],
                         {'driver': 'codex', 'config': {'binaryPath': '/x'}})

    def test_an_existing_instance_wins_and_the_legacy_block_goes(self):
        instance = {'driver': 'claudeAgent', 'config': {'launchArgs': '--add-dir x', 'binaryPath': '/new'}}
        self.seed({'providers': {'claudeAgent': {'binaryPath': '/old'}},
                   'providerInstances': {'claudeAgent': instance}})
        self.merge()
        self.assertEqual(self.read(), {'providerInstances': {
            'claudeAgent': instance, 'antigravity': {'enabled': True}}})

    def test_an_empty_legacy_block_makes_no_instance(self):
        self.seed({'providers': {'codex': {}}})
        self.merge()
        self.assertNotIn('codex', self.read()['providerInstances'])
        self.assertNotIn('providers', self.read())

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed({'providers': {'claudeAgent': {'binaryPath': '/opt/claude'}}})
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_a_non_object_block_is_left_alone(self):
        self.seed({'providers': ['claudeAgent']})
        self.merge()
        self.assertEqual(self.read()['providers'], ['claudeAgent'])

    def test_refuses_malformed_declarations(self):
        for migration in ({'from': 'providers', 'to': 'providerInstances'},
                          dict(MIGRATE, kinds='codex'),
                          dict(MIGRATE, to='providers'),
                          dict(MIGRATE, extra=1)):
            with self.subTest(migration=migration):
                self.declared.write_text(json.dumps({'migrateInstances': migration}))
                with self.assertRaises(ValueError):
                    merger.declaration(self.declared)

    def test_refuses_a_migrated_key_that_is_also_removed(self):
        self.declared.write_text(json.dumps({'migrateInstances': MIGRATE, 'remove': ['providers']}))
        with self.assertRaises(ValueError):
            merger.declaration(self.declared)


PREFIX = '/home/h82/.local/share/agent-plugins/compound-engineering/'
PREFIX_VALUE = PREFIX + 'v3.31.0'
USER_PLUGIN = 'some-plugin@git+https://example.com/some-plugin.git'


class PrefixEntryTests(unittest.TestCase):
    """A prefix-entry list holds the user's entries beside the declared path."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.agent/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(PREFIX_VALUE)

    def declare(self, value, path=('plugins',), prefix=PREFIX, **fields):
        document = {'prefixEntries': [{'path': list(path), 'prefix': prefix, 'value': value}]}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def test_replaces_an_older_entry_and_keeps_the_user_entry(self):
        self.seed({'model': 'x', 'plugins': [USER_PLUGIN, PREFIX + 'v3.30.0']})
        self.merge()
        self.assertEqual(self.read(), {'model': 'x', 'plugins': [USER_PLUGIN, PREFIX_VALUE]})

    def test_second_run_adds_no_duplicate_and_does_not_rewrite(self):
        self.seed({'plugins': [USER_PLUGIN]})
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual(self.read()['plugins'], [USER_PLUGIN, PREFIX_VALUE])
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_collapses_repeated_entries_under_the_prefix(self):
        # A harness loads an entry listed twice twice.
        self.seed({'plugins': [PREFIX_VALUE, USER_PLUGIN, PREFIX_VALUE]})
        self.merge()
        self.assertEqual(self.read()['plugins'], [USER_PLUGIN, PREFIX_VALUE])

    def test_creates_the_list_when_absent(self):
        self.merge()
        self.assertEqual(self.read(), {'plugins': [PREFIX_VALUE]})

    def test_null_value_retires_every_entry_under_the_prefix(self):
        self.seed({'plugins': [PREFIX + 'v3.30.0', USER_PLUGIN, PREFIX_VALUE]})
        self.declare(None)
        self.merge()
        self.assertEqual(self.read()['plugins'], [USER_PLUGIN])

    def test_retiring_from_an_absent_list_adds_nothing(self):
        self.seed({'model': 'x'})
        self.declare(None)
        self.merge()
        self.assertEqual(self.read(), {'model': 'x'})

    def test_non_string_entries_stay(self):
        entry = ['tuple-plugin', {'option': True}]
        self.seed({'plugins': [entry, PREFIX + 'v3.30.0']})
        self.merge()
        self.assertEqual(self.read()['plugins'], [entry, PREFIX_VALUE])

    def test_a_sibling_directory_sharing_the_name_stem_stays(self):
        # The prefix ends in a separator, so another plugin's base survives.
        sibling = PREFIX.rstrip('/') + '-extra/v1'
        self.seed({'plugins': [sibling]})
        self.merge()
        self.assertEqual(self.read()['plugins'], [sibling, PREFIX_VALUE])

    def test_nested_path(self):
        self.seed({'outer': {'keep': 1}})
        self.declare(PREFIX_VALUE, path=('outer', 'plugins'))
        self.merge()
        self.assertEqual(self.read(), {'outer': {'keep': 1, 'plugins': [PREFIX_VALUE]}})

    def test_creates_missing_parents_and_keeps_siblings(self):
        self.seed({'model': 'x', 'outer': {'keep': 1}})
        self.declare(PREFIX_VALUE, path=('outer', 'inner', 'plugins'))
        self.merge()
        self.assertEqual(
            self.read(),
            {'model': 'x', 'outer': {'keep': 1, 'inner': {'plugins': [PREFIX_VALUE]}}})

    def test_does_not_mutate_the_read_document(self):
        current = {'plugins': [PREFIX + 'v3.30.0']}
        merger.apply(current, {}, [], [], prefixes=[(['plugins'], PREFIX, PREFIX_VALUE)])
        self.assertEqual(current, {'plugins': [PREFIX + 'v3.30.0']})

    def assert_refused(self, document, seeded=None):
        self.seed(seeded if seeded is not None else {'plugins': [USER_PLUGIN]})
        self.declared.write_text(json.dumps(document))
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_refuses_a_non_list_at_the_path(self):
        for value in ({'a': 1}, 'one-plugin', 3):
            with self.subTest(value=value):
                self.assert_refused(
                    {'prefixEntries': [{'path': ['plugins'], 'prefix': PREFIX, 'value': PREFIX_VALUE}]},
                    seeded={'plugins': value})

    def test_refuses_malformed_declarations(self):
        entry = {'path': ['plugins'], 'prefix': PREFIX, 'value': PREFIX_VALUE}
        for document in (
            {'prefixEntries': entry},
            {'prefixEntries': [{'path': ['plugins'], 'prefix': PREFIX}]},
            {'prefixEntries': [dict(entry, extra=1)]},
            {'prefixEntries': [dict(entry, path=[])]},
            {'prefixEntries': [dict(entry, prefix='')]},
            {'prefixEntries': [dict(entry, prefix=1)]},
            {'prefixEntries': [dict(entry, value=1)]},
            {'prefixEntries': [dict(entry, value=[PREFIX_VALUE])]},
            # A value outside its own prefix would never be replaced.
            {'prefixEntries': [dict(entry, value='/elsewhere/v3.31.0')]},
        ):
            with self.subTest(document=document):
                self.assert_refused(document)

    def test_refuses_a_path_another_declaration_touches(self):
        entry = {'path': ['plugins'], 'prefix': PREFIX, 'value': PREFIX_VALUE}
        for field in ({'set': {'plugins': 1}},
                      {'remove': ['plugins']},
                      {'own': {'plugins': []}},
                      {'setPaths': [{'path': ['plugins', 'x'], 'value': 1}]},
                      {'upsertPaths': [{'path': ['plugins'], 'key': 'name', 'value': {'name': 'a'}}]},
                      {'prefixEntries': [dict(entry, prefix=PREFIX + 'v')]}):
            with self.subTest(field=field):
                document = dict(field)
                document['prefixEntries'] = [entry] + document.get('prefixEntries', [])
                self.assert_refused(document)

    def test_process_merges_prefix_entries(self):
        self.seed({'plugins': [USER_PLUGIN]})
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--settings', str(self.settings),
             '--declared', str(self.declared), '--label', 'Agent'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['plugins'], [USER_PLUGIN, PREFIX_VALUE])


REMOVE_EXISTING = {
    'colorPalette': 'blue',
    'scanner': {'bucketTimezone': 'Asia/Seoul', 'retired': 'stale', 'live': 'keep'},
    'autosubmit': {'enabled': False},
}


class RemovePathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.config/tokscale/settings.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare([{'path': ['scanner'], 'key': 'retired'}],
                     assign={'colorPalette': 'blue'})

    def declare(self, removes, assign=None, **fields):
        document = {'set': assign or {}, 'remove': [], 'removePaths': removes}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else REMOVE_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def assert_refused(self, document):
        self.declared.write_text(json.dumps(document))
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_the_named_key_is_removed_and_its_siblings_survive(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertEqual(result['scanner'], {'bucketTimezone': 'Asia/Seoul', 'live': 'keep'})
        self.assertEqual(result['colorPalette'], 'blue')
        self.assertEqual(result['autosubmit'], REMOVE_EXISTING['autosubmit'])

    def test_removing_an_absent_key_is_a_no_op(self):
        self.seed()
        self.declare([{'path': ['scanner'], 'key': 'elsewhere'}])
        self.merge()
        self.assertEqual(self.read()['scanner'], REMOVE_EXISTING['scanner'])

    def test_an_absent_or_non_object_path_is_a_no_op(self):
        # Mirrors top-level remove: a key that cannot be there is not an error.
        self.seed(dict(REMOVE_EXISTING, scanner='flat'))
        self.declare([{'path': ['scanner'], 'key': 'retired'},
                      {'path': ['nope', 'deep'], 'key': 'gone'}])
        self.merge()
        result = self.read()
        self.assertEqual(result['scanner'], 'flat')
        self.assertNotIn('nope', result)

    def test_deeper_removals_remove_only_the_named_leaf(self):
        self.seed({'a': {'keep': 1, 'b': {'retired': 2, 'live': 3}}})
        self.declare([{'path': ['a', 'b'], 'key': 'retired'}])
        self.merge()
        self.assertEqual(self.read(), {'a': {'keep': 1, 'b': {'live': 3}}})

    def test_a_missing_file_creates_no_declared_keys(self):
        self.declare([{'path': ['scanner'], 'key': 'retired'}])
        self.merge()
        self.assertEqual(self.read(), {})

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual(before.st_ino, after.st_ino)
        self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)

    def test_a_segment_containing_a_dot_is_one_key(self):
        self.seed({'a.b': {'retired': 1}})
        self.declare([{'path': ['a.b'], 'key': 'retired'}])
        self.merge()
        self.assertEqual(self.read(), {'a.b': {}})

    def test_refuses_malformed_remove_declarations(self):
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for document in (
            {'removePaths': entry},
            {'removePaths': [{'path': ['scanner']}]},
            {'removePaths': [dict(entry, extra=1)]},
            {'removePaths': [dict(entry, path=[])]},
            {'removePaths': [dict(entry, path='scanner')]},
            {'removePaths': [dict(entry, key=3)]},
            {'removePaths': [dict(entry, value='stale', values=['stale'])]},
            {'removePaths': [dict(entry, values='stale')]},
            {'removePaths': [dict(entry, values=[['stale']])]},
            {'removePaths': [dict(entry, migration='')]},
            {'removePaths': [dict(entry, migration=3)]},
        ):
            with self.subTest(document=document):
                self.assert_refused(document)

    def test_refuses_a_removal_on_a_key_set_removed_or_owned(self):
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for field in ({'set': {'scanner': 1}},
                      {'remove': ['scanner']},
                      {'own': {'scanner': {}}}):
            with self.subTest(field=field):
                self.assert_refused(dict(field, removePaths=[entry]))

    def test_refuses_a_removal_whose_leaf_another_declaration_claims(self):
        # The removal's leaf is scanner.retired. A declaration that sets or
        # manages that node, or an ancestor of it, would fight the removal
        # with an outcome that depends on the order they run in.
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for field in ({'setPaths': [{'path': ['scanner', 'retired'], 'value': 1}]},
                      {'setPaths': [{'path': ['scanner'], 'value': 1}]},
                      {'upsertPaths': [{'path': ['scanner', 'retired'], 'key': 'name',
                                        'value': {'name': 'a'}}]},
                      {'prefixEntries': [{'path': ['scanner', 'retired'], 'prefix': 'p',
                                          'value': 'pv'}]}):
            with self.subTest(field=field):
                self.assert_refused(dict(field, removePaths=[entry]))

    def test_refuses_overlapping_or_repeated_removals(self):
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for second in (
            entry,
            dict(entry, path=['scanner', 'retired'], key='inner'),
        ):
            with self.subTest(second=second):
                self.assert_refused({'removePaths': [entry, second]})

    def test_two_removals_may_name_different_keys_of_one_object(self):
        self.seed()
        self.declare([{'path': ['scanner'], 'key': 'retired'},
                      {'path': ['scanner'], 'key': 'live'}])
        self.merge()
        self.assertEqual(self.read()['scanner'], {'bucketTimezone': 'Asia/Seoul'})

    def declare_pruned(self, **fields):
        self.declare([{'path': ['modelSettings', 'claude-opus-5-5'], 'key': 'effortLevel', 'prune': True}],
                     **fields)

    def test_prune_removes_each_object_the_removal_empties(self):
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'medium'}}, 'colorPalette': 'blue'})
        self.declare_pruned(assign={'colorPalette': 'blue'})
        self.merge()
        self.assertEqual(self.read(), {'colorPalette': 'blue'})

    def test_prune_keeps_a_sibling_key_and_a_sibling_model(self):
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'medium', 'other': 1}}})
        self.declare_pruned()
        self.merge()
        self.assertEqual(self.read(), {'modelSettings': {'claude-opus-5-5': {'other': 1}}})
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'medium'}, 'claude-sonnet-5-5': {'x': 1}}})
        self.merge()
        self.assertEqual(self.read(), {'modelSettings': {'claude-sonnet-5-5': {'x': 1}}})

    def test_prune_leaves_a_file_without_the_path_untouched(self):
        self.seed({'colorPalette': 'blue'})
        self.declare_pruned(assign={'colorPalette': 'blue'})
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_a_removal_without_prune_leaves_the_emptied_parent(self):
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'medium'}}})
        self.declare([{'path': ['modelSettings', 'claude-opus-5-5'], 'key': 'effortLevel'}])
        self.merge()
        self.assertEqual(self.read(), {'modelSettings': {'claude-opus-5-5': {}}})

    def test_prune_leaves_an_existing_empty_parent_whose_key_is_absent(self):
        # Nothing was removed, so nothing was emptied by this removal.
        self.seed({'modelSettings': {'claude-opus-5-5': {}}})
        self.declare_pruned()
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.read(), {'modelSettings': {'claude-opus-5-5': {}}})
        self.assertEqual(self.settings.read_bytes(), before)

    def test_prune_through_a_non_object_segment_is_a_no_op(self):
        self.declare_pruned(assign={'colorPalette': 'blue'})
        for middle in ('flat', 5, True, ['claude-opus-5-5']):
            with self.subTest(middle=middle):
                self.seed({'modelSettings': middle, 'colorPalette': 'blue'})
                before = self.settings.read_bytes()
                self.merge()
                self.assertEqual(self.settings.read_bytes(), before)

    def test_pruning_and_plain_removals_under_one_object_give_one_result_in_either_order(self):
        seed = {'a': {'b': {'x': 1, 'y': 2}}, 'keep': True}
        pruning = {'path': ['a', 'b'], 'key': 'x', 'prune': True}
        plain = {'path': ['a', 'b'], 'key': 'y'}
        results = []
        for order in ([pruning, plain], [plain, pruning]):
            self.seed(seed)
            self.declare(order)
            self.merge()
            results.append(self.read())
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], {'keep': True})

    def test_a_removal_with_a_value_removes_the_key_only_when_it_holds_that_value(self):
        entry = {'path': ['scanner'], 'key': 'retired', 'value': 'stale'}
        self.seed()
        self.declare([entry])
        self.merge()
        self.assertEqual(self.read()['scanner'], {'bucketTimezone': 'Asia/Seoul', 'live': 'keep'})
        self.seed(dict(REMOVE_EXISTING, scanner={'retired': 'mine'}))
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_a_removal_with_values_removes_the_key_while_it_holds_any_of_them(self):
        levels = ['modelThinkingLevels']
        self.seed({'modelThinkingLevels': {'synthetic/a': 'low', 'synthetic/b': 'high', 'synthetic/c': 'max'}})
        self.declare([{'path': levels, 'key': key, 'values': ['low', 'high']}
                      for key in ('synthetic/a', 'synthetic/b', 'synthetic/c')])
        self.merge()
        self.assertEqual(self.read(), {'modelThinkingLevels': {'synthetic/c': 'max'}})

    def test_a_removal_with_a_value_never_matches_across_bool_and_number(self):
        self.seed({'scanner': {'retired': True}})
        self.declare([{'path': ['scanner'], 'key': 'retired', 'value': 1}])
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_a_pruning_removal_whose_value_differs_prunes_nothing(self):
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'xhigh'}}})
        self.declare([{'path': ['modelSettings', 'claude-opus-5-5'], 'key': 'effortLevel',
                       'prune': True, 'value': 'medium'}])
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_a_pruning_removal_whose_value_matches_prunes_the_emptied_objects(self):
        self.seed({'modelSettings': {'claude-opus-5-5': {'effortLevel': 'medium'}}})
        self.declare([{'path': ['modelSettings', 'claude-opus-5-5'], 'key': 'effortLevel',
                       'prune': True, 'value': 'medium'}])
        self.merge()
        self.assertEqual(self.read(), {})

    def test_refuses_a_removal_value_that_is_not_a_scalar(self):
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for value in ({'a': 1}, ['stale']):
            with self.subTest(value=value):
                self.assert_refused({'removePaths': [dict(entry, value=value)]})

    def test_refuses_a_prune_that_is_not_a_boolean(self):
        self.seed()
        entry = {'path': ['scanner'], 'key': 'retired'}
        for prune in ('yes', 1, None, []):
            with self.subTest(prune=prune):
                self.assert_refused({'removePaths': [dict(entry, prune=prune)]})

    def test_a_nested_leaf_is_assigned_beside_the_users_keys(self):
        self.seed({'worktree': {'symlinkDirectories': ['node_modules']}})
        self.declare([], setPaths=[{'path': ['worktree', 'baseRef'], 'value': 'head'}])
        self.merge()
        self.assertEqual(self.read()['worktree'],
                         {'symlinkDirectories': ['node_modules'], 'baseRef': 'head'})

    def test_process_removes_the_named_leaf(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--settings', str(self.settings),
             '--declared', str(self.declared), '--label', 'Tokscale'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['scanner'], {'bucketTimezone': 'Asia/Seoul', 'live': 'keep'})


# A provider's model list as Pi keeps it: entries by `id`, one the
# declaration retires, one it keeps, one the user added, and non-object
# entries a removal must leave alone.
DROP_EXISTING = {
    'providers': {
        'synthetic': {
            'baseUrl': 'https://example.invalid/v1',
            'models': [
                {'id': 'hf:org/Retired-1', 'name': 'old build'},
                {'id': 'hf:org/Current-2', 'name': 'current'},
                {'id': 'hf:user/Hand-Added', 'name': 'mine'},
                {'id': 'hf:org/Retired-1', 'name': 'a duplicate'},
                'a bare string',
                {'name': 'no id'},
            ],
        },
        'other': {'models': [{'id': 'hf:org/Retired-1'}]},
    },
    'defaultProvider': 'synthetic',
}
DROP_PATH = ['providers', 'synthetic', 'models']


class RemoveEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.pi/agent/models.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare([{'path': DROP_PATH, 'key': 'id', 'values': ['hf:org/Retired-1']}])

    def declare(self, drops, **fields):
        document = {'removeEntries': drops}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else DROP_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared)

    def read(self):
        return json.loads(self.settings.read_text())

    def assert_refused(self, document):
        self.declared.write_text(json.dumps(document))
        before = self.settings.read_bytes()
        with self.assertRaises(ValueError):
            self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_every_matching_entry_goes_and_the_rest_stay_in_order(self):
        self.seed()
        self.merge()
        result = self.read()
        self.assertEqual(result['providers']['synthetic']['models'], [
            {'id': 'hf:org/Current-2', 'name': 'current'},
            {'id': 'hf:user/Hand-Added', 'name': 'mine'},
            'a bare string',
            {'name': 'no id'},
        ])
        self.assertEqual(result['providers']['other'], DROP_EXISTING['providers']['other'])
        self.assertEqual(result['providers']['synthetic']['baseUrl'], 'https://example.invalid/v1')
        self.assertEqual(result['defaultProvider'], 'synthetic')

    def test_several_values_and_an_empty_list(self):
        self.seed()
        self.declare([{'path': DROP_PATH, 'key': 'id', 'values': ['hf:org/Retired-1', 'hf:org/Current-2']}])
        self.merge()
        self.assertEqual([m['id'] for m in self.read()['providers']['synthetic']['models'] if isinstance(m, dict) and 'id' in m],
                         ['hf:user/Hand-Added'])
        self.seed()
        self.declare([{'path': DROP_PATH, 'key': 'id', 'values': []}])
        before = self.settings.read_bytes()
        self.merge()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_values_match_by_equality_not_by_prefix_or_type(self):
        self.seed({'list': [{'id': 'hf:org/Retired-10'}, {'id': 1}, {'id': '1'}, {'id': True}]})
        self.declare([{'path': ['list'], 'key': 'id', 'values': ['hf:org/Retired-1', '1']}])
        self.merge()
        self.assertEqual(self.read()['list'], [{'id': 'hf:org/Retired-10'}, {'id': 1}, {'id': True}])
        self.declare([{'path': ['list'], 'key': 'id', 'values': [1]}])
        self.merge()
        self.assertEqual(self.read()['list'], [{'id': 'hf:org/Retired-10'}, {'id': True}])

    def test_an_absent_or_non_list_path_is_a_no_op(self):
        for data in ({'providers': {'synthetic': {'models': {'id': 'hf:org/Retired-1'}}}},
                     {'providers': {'synthetic': 'flat'}},
                     {'unrelated': 1}):
            with self.subTest(data=data):
                self.seed(data)
                self.merge()
                self.assertEqual(self.read(), data)

    def test_a_missing_file_creates_nothing(self):
        self.merge()
        self.assertEqual(self.read(), {})

    def test_second_run_does_not_rewrite_the_file(self):
        self.seed()
        self.merge()
        before = self.settings.stat()
        self.merge()
        after = self.settings.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_an_upsert_of_another_entry_in_the_same_list_runs_beside_it(self):
        self.seed()
        self.declare([{'path': DROP_PATH, 'key': 'id', 'values': ['hf:org/Retired-1']}],
                     upsertPaths=[{'path': DROP_PATH, 'key': 'id', 'value': {'id': 'hf:org/New-3', 'name': 'new'}}])
        self.merge()
        ids = [m.get('id') for m in self.read()['providers']['synthetic']['models'] if isinstance(m, dict)]
        self.assertEqual(ids, ['hf:org/Current-2', 'hf:user/Hand-Added', None, 'hf:org/New-3'])

    def test_refuses_malformed_declarations(self):
        self.seed()
        entry = {'path': DROP_PATH, 'key': 'id', 'values': ['x']}
        for document in (
            {'removeEntries': entry},
            {'removeEntries': [{'path': DROP_PATH, 'key': 'id'}]},
            {'removeEntries': [dict(entry, extra=1)]},
            {'removeEntries': [dict(entry, path=[])]},
            {'removeEntries': [dict(entry, path='providers')]},
            {'removeEntries': [dict(entry, key=3)]},
            {'removeEntries': [dict(entry, values='x')]},
            {'removeEntries': [dict(entry, values=[{'id': 'x'}])]},
            {'removeEntries': [dict(entry, values=[['x']])]},
        ):
            with self.subTest(document=document):
                self.assert_refused(document)

    def test_refuses_a_removal_another_declaration_would_fight(self):
        self.seed()
        entry = {'path': DROP_PATH, 'key': 'id', 'values': ['hf:org/Retired-1']}
        for field in (
            {'set': {'providers': 1}},
            {'remove': ['providers']},
            {'own': {'providers': {}}},
            {'setPaths': [{'path': ['providers', 'synthetic', 'models'], 'value': 1}]},
            {'setPaths': [{'path': ['providers', 'synthetic'], 'value': 1}]},
            {'removePaths': [{'path': ['providers', 'synthetic'], 'key': 'models'}]},
            {'prefixEntries': [{'path': DROP_PATH, 'prefix': 'p', 'value': None}]},
            # An upsert of the entry the removal drops, or one keyed by
            # another field, would undo it or race it.
            {'upsertPaths': [{'path': DROP_PATH, 'key': 'id', 'value': {'id': 'hf:org/Retired-1'}}]},
            {'upsertPaths': [{'path': DROP_PATH, 'key': 'name', 'value': {'name': 'x'}}]},
            {'removeEntries': [entry, dict(entry, values=['other'])]},
        ):
            with self.subTest(field=field):
                document = {'removeEntries': [entry]}
                document.update(field)
                self.assert_refused(document)

    def test_process_drops_the_named_entries(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--settings', str(self.settings),
             '--declared', str(self.declared), '--label', 'Pi'],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('hf:org/Retired-1', json.dumps(self.read()['providers']['synthetic']))


# Pi's models.json with no ledger record: two models its `preLedgerIds` name,
# one the user added, and siblings no declaration names.  The stale
# name on Current-2 makes a run that skips the upsert differ from one that
# applies it.
OWN_PATH = ['providers', 'synthetic', 'models']
OVERRIDE_PATH = ['providers', 'openrouter', 'modelOverrides']
PRE_LEDGER = ['hf:org/Retired-1', 'hf:org/Current-2']
HAND_ADDED = {'id': 'hf:user/Hand-Added', 'name': 'mine'}
OWN_EXISTING = {
    'providers': {
        'synthetic': {
            'baseUrl': 'https://example.invalid/v1',
            'models': [
                {'id': 'hf:org/Retired-1', 'name': 'old build'},
                {'id': 'hf:org/Current-2', 'name': 'stale name'},
                HAND_ADDED,
            ],
        },
        'openrouter': {'modelOverrides': {'user/hand': {'name': 'mine'}}},
    },
    'defaultProvider': 'synthetic',
}


def model(model_id):
    return {'id': model_id, 'name': 'declared ' + model_id}


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.settings = Path(self.tmp.name) / 'home/.pi/agent/models.json'
        self.ledger = Path(self.tmp.name) / 'state/nix-config/agent-settings-ledger/.pi/agent/models.json'
        self.declared = Path(self.tmp.name) / 'declared.json'
        self.declare(['hf:org/Current-2', 'hf:org/New-3'])

    def declare(self, ids, overrides=None, **fields):
        owned = [{'path': OWN_PATH, 'key': 'id', 'entries': [model(i) for i in ids],
                  'preLedgerIds': PRE_LEDGER}]
        if overrides is not None:
            owned.append({'path': OVERRIDE_PATH,
                          'entries': {name: {'name': 'declared ' + name} for name in overrides}})
        document = {'ownEntries': owned}
        document.update(fields)
        self.declared.write_text(json.dumps(document))

    def seed(self, data=None):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(data if data is not None else OWN_EXISTING, indent=2))
        self.settings.chmod(0o600)

    def merge(self):
        merger.merge(self.settings, self.declared, ledger=self.ledger)

    def read(self):
        return json.loads(self.settings.read_text())

    def models(self):
        return self.read()['providers']['synthetic']['models']

    def run_script(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--label', 'Pi models', '--settings', str(self.settings),
             '--declared', str(self.declared), '--ledger', str(self.ledger)],
            capture_output=True, text=True)

    def merge_failing_the_settings_replace(self, landed):
        """Kill a real apply immediately before or after its settings rename."""
        worker = '''
import os, runpy, sys
from pathlib import Path
scope = runpy.run_path(sys.argv[1])
settings = Path(sys.argv[2])
original = os.replace
def replace(source, target):
    if Path(target) != settings:
        return original(source, target)
    if sys.argv[5] == 'True':
        original(source, target)
    print('settings-swap', flush=True)
    sys.stdin.readline()
    raise RuntimeError('interrupted apply was resumed')
os.replace = replace
scope['merge'](settings, Path(sys.argv[3]), ledger=Path(sys.argv[4]))
'''
        with subprocess.Popen(
                [sys.executable, '-u', '-c', worker, str(SCRIPT), str(self.settings),
                 str(self.declared), str(self.ledger), str(landed)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            try:
                ready, _, _ = select.select([process.stdout], [], [], 10)
                self.assertTrue(ready, 'apply did not reach the settings rename')
                self.assertEqual(process.stdout.readline(), 'settings-swap\n')
            finally:
                if process.poll() is None:
                    process.kill()
                _, stderr = process.communicate(timeout=10)
            self.assertLess(process.returncode, 0, stderr)

    def test_first_apply_without_a_ledger_prunes_a_pre_ledger_id_and_keeps_a_hand_added_entry(self):
        self.seed()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED, model('hf:org/New-3')])
        merged = self.read()
        self.assertEqual(merged['providers']['openrouter'], OWN_EXISTING['providers']['openrouter'])
        self.assertEqual(merged['providers']['synthetic']['baseUrl'], 'https://example.invalid/v1')
        self.assertEqual(merged['defaultProvider'], 'synthetic')
        self.assertEqual(self.ledger.stat().st_mode & 0o777, 0o600)

    def test_second_apply_removes_exactly_the_entry_it_no_longer_declares(self):
        self.seed()
        self.merge()
        self.declare(['hf:org/Current-2'])
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED])

    def test_a_hand_added_entry_that_becomes_declared_is_replaced_then_removed_when_dropped(self):
        self.seed()
        self.declare(['hf:org/Current-2', HAND_ADDED['id']])
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), model(HAND_ADDED['id'])])
        self.declare(['hf:org/Current-2'])
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2')])

    def test_an_entry_the_user_adds_back_after_the_declaration_dropped_it_stays(self):
        # Once an apply has removed an entry, it no longer owns that ID.
        self.seed()
        self.merge()
        self.declare(['hf:org/Current-2'])
        self.merge()
        mine = {'id': 'hf:org/New-3', 'name': 'added back by hand'}
        self.seed(dict(OWN_EXISTING, providers=dict(OWN_EXISTING['providers'], synthetic={
            'baseUrl': 'https://example.invalid/v1', 'models': self.models() + [mine]})))
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED, mine])

    def test_an_object_path_removes_a_key_it_wrote_and_keeps_one_it_never_wrote(self):
        self.seed()
        self.declare(['hf:org/Current-2'], overrides=['x/a', 'x/b'])
        self.merge()
        self.declare(['hf:org/Current-2'], overrides=['x/a'])
        self.merge()
        self.assertEqual(self.read()['providers']['openrouter']['modelOverrides'],
                         {'user/hand': {'name': 'mine'}, 'x/a': {'name': 'declared x/a'}})

    def test_an_apply_interrupted_after_the_settings_write_still_owns_what_it_wrote(self):
        self.seed()
        self.merge_failing_the_settings_replace(landed=True)
        self.assertIn(model('hf:org/New-3'), self.models())
        # An agent's later save changes the digest of the landed settings.
        edited = self.read()
        edited['userPreference'] = 'keep me'
        self.seed(edited)
        self.declare(['hf:org/Current-2'])
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED])
        self.assertEqual(self.read()['userPreference'], 'keep me')

    def test_an_apply_interrupted_before_the_swap_does_not_claim_a_user_entry(self):
        self.seed()
        self.declare(['hf:org/Current-2', HAND_ADDED['id']])
        before = self.settings.read_bytes()
        self.merge_failing_the_settings_replace(landed=False)
        self.assertEqual(self.settings.read_bytes(), before)
        self.declare(['hf:org/Current-2'])
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED])

    def test_interrupted_migration_runs_only_if_its_settings_swap_did_not_land(self):
        self.declared.write_text(json.dumps({'removePaths': [
            {'path': ['modelThinkingLevels'], 'key': 'synthetic/a', 'value': 'max',
             'migration': 'startup-levels'},
        ]}))
        for landed in (False, True):
            with self.subTest(landed=landed):
                self.ledger.unlink(missing_ok=True)
                self.seed({'modelThinkingLevels': {'synthetic/a': 'max'}})
                self.merge_failing_the_settings_replace(landed=landed)
                self.assertEqual(self.read()['modelThinkingLevels'], {} if landed else {'synthetic/a': 'max'})
                # A user restores the old level after a successful swap.
                self.seed({'modelThinkingLevels': {'synthetic/a': 'max'}, 'userPreference': 'keep me'})
                self.merge()
                self.assertEqual(self.read(), {
                    'modelThinkingLevels': {'synthetic/a': 'max'} if landed else {},
                    'userPreference': 'keep me',
                })

    def test_overlapping_applies_keep_both_paths_owned_until_the_next_prune(self):
        self.seed()
        second = self.declared.with_name('second.json')
        second.write_text(json.dumps({'ownEntries': [
            {'path': OVERRIDE_PATH, 'entries': {'x/b': {'name': 'second apply'}}},
        ]}))
        # Pause A immediately after reading the ledger. B either waits for
        # the settings lock or completes before A resumes on an unfixed
        # merger. Pipes establish the schedule without a timing sleep.
        worker = '''
import fcntl, runpy, sys
from pathlib import Path
scope = runpy.run_path(sys.argv[1])
merge = scope['merge']
original_read = merge.__globals__['read_ledger']
original_lock = fcntl.flock
first_read = True
def read_ledger(path):
    global first_read
    state = original_read(path)
    if first_read:
        first_read = False
        print('ledger-read', flush=True)
        if sys.argv[5] == 'A':
            assert sys.stdin.readline() == 'resume\\n'
    return state
def flock(fd, operation):
    if operation == fcntl.LOCK_EX and sys.argv[5] == 'B':
        print('locking', flush=True)
    return original_lock(fd, operation)
merge.__globals__['read_ledger'] = read_ledger
fcntl.flock = flock
merge(Path(sys.argv[2]), Path(sys.argv[3]), ledger=Path(sys.argv[4]))
'''

        def start(declared, role):
            process = subprocess.Popen(
                [sys.executable, '-u', '-c', worker, str(SCRIPT), str(self.settings),
                 str(declared), str(self.ledger), role],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

            def cleanup():
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=10)

            self.addCleanup(cleanup)
            return process

        def signal(process):
            readable, _, _ = select.select([process.stdout], [], [], 10)
            self.assertTrue(readable, 'apply did not reach its synchronization point')
            line = process.stdout.readline().strip()
            self.assertTrue(line, 'apply exited before its synchronization point')
            return line

        first = start(self.declared, 'A')
        self.assertEqual(signal(first), 'ledger-read')
        other = start(second, 'B')
        if signal(other) == 'ledger-read':
            _, stderr = other.communicate(timeout=10)
            self.assertEqual(other.returncode, 0, stderr)
        first.stdin.write('resume\n')
        first.stdin.flush()
        for process in (first, other):
            _, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
        self.declare([], overrides=[])
        self.merge()
        self.assertEqual(self.models(), [HAND_ADDED])
        self.assertEqual(self.read()['providers']['openrouter']['modelOverrides'],
                         {'user/hand': {'name': 'mine'}})

    def test_owned_paths_with_the_wrong_shape_fail_without_writing_settings_or_a_ledger(self):
        self.declare(['hf:org/Current-2'], overrides=['x/a'])
        for path, malformed in ((OWN_PATH, {'not': 'a list'}), (OVERRIDE_PATH, ['not an object'])):
            with self.subTest(path=path):
                data = json.loads(json.dumps(OWN_EXISTING))
                data[path[0]][path[1]][path[2]] = malformed
                self.seed(data)
                before = self.settings.read_bytes()
                with self.assertRaises(ValueError) as error:
                    self.merge()
                self.assertIn(json.dumps(path), str(error.exception))
                self.assertEqual(self.settings.read_bytes(), before)
                self.assertFalse(self.ledger.exists())

    def test_owned_upserts_keep_the_first_position_and_unowned_duplicates(self):
        self.seed({'providers': {'synthetic': {'models': [
            {'id': 'hf:org/Current-2', 'name': 'first'}, HAND_ADDED,
            {'id': 'hf:org/Current-2', 'name': 'duplicate'}, HAND_ADDED,
        ]}}})
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED, HAND_ADDED,
                                         model('hf:org/New-3')])

    def test_an_external_save_during_the_pending_record_is_merged_on_retry(self):
        self.seed()
        original = os.replace
        saved = False

        def replace(source, target):
            nonlocal saved
            original(source, target)
            if Path(target) == self.ledger and not saved:
                saved = True
                edited = self.read()
                edited['userPreference'] = 'saved while journaling'
                self.seed(edited)

        with mock.patch.object(merger.os, 'replace', replace):
            self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED, model('hf:org/New-3')])
        self.assertEqual(self.read().get('userPreference'), 'saved while journaling')

    def test_a_pending_digest_mismatch_fails_without_changing_either_file(self):
        self.seed()
        self.merge_failing_the_settings_replace(landed=False)
        journal = json.loads(self.ledger.read_text())
        journal['pending']['digest'] = '0' * 64
        self.ledger.write_text(json.dumps(journal))
        before = self.settings.read_bytes(), self.ledger.read_bytes()
        result = self.run_script()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(str(self.ledger), result.stderr)
        self.assertIn('digest', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual((self.settings.read_bytes(), self.ledger.read_bytes()), before)

    def test_a_failed_settings_write_keeps_ownership_for_the_next_apply(self):
        self.seed()
        self.merge()
        self.declare(['hf:org/Current-2'])
        before = self.settings.read_bytes()
        self.merge_failing_the_settings_replace(landed=False)
        self.assertEqual(self.settings.read_bytes(), before)
        self.merge()
        self.assertEqual(self.models(), [model('hf:org/Current-2'), HAND_ADDED])

    def test_a_malformed_ledger_fails_naming_it_and_leaves_the_settings_unchanged(self):
        self.seed()
        self.ledger.parent.mkdir(parents=True)
        for text in ('{ not json', '[]', '{"owned": "x"}',
                     '{"owned": [{"path": ["providers"], "ids": [1]}]}'):
            with self.subTest(text=text):
                self.ledger.write_text(text)
                before = self.settings.read_bytes()
                result = self.run_script()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('Pi models settings merge failed', result.stderr)
                self.assertIn(str(self.ledger), result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertEqual(self.settings.read_bytes(), before)
                self.assertEqual(self.ledger.read_text(), text)

    def test_the_same_declaration_twice_leaves_both_files_byte_identical(self):
        self.seed()
        self.declare(['hf:org/Current-2', 'hf:org/New-3'], overrides=['x/a'])
        self.merge()

        def state(path):
            stat = path.stat()
            return path.read_bytes(), stat.st_ino, stat.st_mtime_ns

        before = [state(self.settings), state(self.ledger)]
        self.merge()
        self.assertEqual([state(self.settings), state(self.ledger)], before)

    def test_a_one_time_migration_runs_on_the_first_apply_only(self):
        levels = ['modelThinkingLevels']
        self.declared.write_text(json.dumps({'removePaths': [
            {'path': levels, 'key': 'synthetic/a', 'value': 'max', 'migration': 'startup-levels'},
            {'path': levels, 'key': 'synthetic/b', 'values': ['low', 'high'], 'migration': 'startup-levels'},
        ]}))
        # The first apply either removes the declared values or,
        # on a host that never held those values, finds nothing; it counts as
        # run either way.
        for first, migrated in (
            ({'synthetic/a': 'max', 'synthetic/b': 'high', 'synthetic/c': 'medium'}, {'synthetic/c': 'medium'}),
            ({'synthetic/c': 'medium'}, {'synthetic/c': 'medium'}),
        ):
            with self.subTest(first=first):
                self.ledger.unlink(missing_ok=True)
                self.seed({'modelThinkingLevels': first})
                self.merge()
                self.assertEqual(self.read(), {'modelThinkingLevels': migrated})
                # The user saves levels equal to the migrated ones through /thinking.
                self.seed({'modelThinkingLevels': {'synthetic/a': 'max', 'synthetic/b': 'low', 'synthetic/c': 'medium'}})
                before = self.settings.read_bytes()
                self.merge()
                self.assertEqual(self.settings.read_bytes(), before)

    def test_refuses_malformed_or_conflicting_declarations(self):
        self.seed()
        entry = {'path': OWN_PATH, 'key': 'id', 'entries': [model('a')]}
        for document in (
            {'ownEntries': entry},
            {'ownEntries': [dict(entry, extra=1)]},
            {'ownEntries': [dict(entry, path=[])]},
            {'ownEntries': [dict(entry, entries=[{'name': 'no id'}])]},
            {'ownEntries': [dict(entry, entries=[{'id': 1}])]},
            {'ownEntries': [dict(entry, entries=[model('a'), model('a')])]},
            {'ownEntries': [dict(entry, entries={'a': {}})]},
            {'ownEntries': [{'path': OVERRIDE_PATH, 'entries': [model('a')]}]},
            {'ownEntries': [dict(entry, preLedgerIds='a')]},
            {'ownEntries': [entry, entry]},
            {'ownEntries': [entry], 'set': {'providers': 1}},
            {'ownEntries': [entry], 'upsertPaths': [{'path': OWN_PATH, 'key': 'id', 'value': model('b')}]},
            {'ownEntries': [entry], 'removePaths': [{'path': ['providers', 'synthetic'], 'key': 'models'}]},
        ):
            with self.subTest(document=document):
                self.declared.write_text(json.dumps(document))
                before = self.settings.read_bytes()
                with self.assertRaises(ValueError):
                    self.merge()
                self.assertEqual(self.settings.read_bytes(), before)
                self.assertFalse(self.ledger.exists())
        # Owned entries and migrations need somewhere to record what they did.
        for document in ({'ownEntries': [entry]},
                         {'removePaths': [{'path': ['a'], 'key': 'b', 'migration': 'm'}]}):
            with self.subTest(document=document):
                self.declared.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    merger.merge(self.settings, self.declared)
                self.assertEqual(self.read(), OWN_EXISTING)


if __name__ == '__main__':
    unittest.main()
