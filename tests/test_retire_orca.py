"""Check interface:

    python tests/test_retire_orca.py <activation-block> <macos: 0|1>

Runs one user environment's materialized home.activation.retireOrca block, the
packaged helper it calls included, against seeded scratch homes.

The seeds copy the shapes Orca left on a real home: a hook group on every
event whose single hook runs Orca's script, an Orca status line, an
`orca-status` Antigravity hook, the Codex trust entries for its hooks file,
and the two state directories. Entries other tools wrote sit beside them in
the same files, groups, and directories, so a whole-file or whole-group
removal fails the same assertions a correct removal passes.
"""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

BLOCK = Path(sys.argv[1]).read_text()
MACOS = sys.argv[2] == '1'
BASH = shutil.which('bash')

ORCA_CLAUDE = {'type': 'command', 'timeout': 10,
               'command': 'if [ -z "${ORCA_AGENT_HOOK_PORT-}" ]; then exit 0; fi; "$HOME/.orca/agent-hooks/claude-hook.sh"'}
ORCA_CODEX = {'type': 'command',
              'command': "if [ -f '/home/u/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/home/u/.orca/agent-hooks/codex-hook.sh'; fi"}
OTHER = {'type': 'command', 'command': 'notify-send done'}
OTHER_STATUS = {'type': 'command', 'command': 'ccstatusline'}


def claude_settings(status=None, extra_group=None):
    hooks = {event: [{'matcher': '*', 'hooks': [ORCA_CLAUDE]}]
             for event in ('PreToolUse', 'PermissionRequest', 'Stop', 'SessionStart')}
    if extra_group is not None:
        hooks['PreToolUse'].append(extra_group)
    return {'model': 'opus[1m]', 'enabledPlugins': {'x@y': True}, 'hooks': hooks,
            'statusLine': status or {'type': 'command', 'command': 'bash "$HOME/.orca/agent-hooks/claude-statusline.sh"'}}


def codex_hooks(extra=None):
    hooks = {event: [{'hooks': [ORCA_CODEX]}] for event in ('PreToolUse', 'PermissionRequest', 'Stop')}
    if extra is not None:
        hooks['Stop'].append({'hooks': [extra]})
    return {'hooks': hooks}


class RetireOrca(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.home = Path(self.scratch.name)

    def tearDown(self):
        self.scratch.cleanup()

    def put(self, relative, content):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content if isinstance(content, str) else json.dumps(content, indent=2) + '\n')
        return path

    def json(self, relative):
        return json.loads((self.home / relative).read_text())

    def seed(self, claude=None, codex=None):
        self.put('.claude/settings.json', claude or claude_settings())
        self.put('.codex/hooks.json', codex or codex_hooks())
        hooks = self.home / '.codex/hooks.json'
        self.put('.codex/config.toml', (
            '# keep me\nmodel = "gpt"\n\n[hooks.state]\n\n'
            '[hooks.state."{0}:pre_tool_use:0:0"]\ntrusted_hash = "sha256:a"\n\n'
            '[hooks.state."{0}:stop:0:0"]\ntrusted_hash = "sha256:b"\n\n'
            '[hooks.state."/elsewhere/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:c"\n\n'
            '[projects."/src/x"]\ntrust_level = "trusted"\n').format(hooks))
        self.put('.gemini/config/hooks.json', {
            'orca-status': {'Stop': [{'type': 'command', 'command': "/bin/sh '/home/u/.orca/agent-hooks/antigravity-hook.sh'"}]},
            'mine': {'Stop': [OTHER]}})
        self.put('.orca/agent-hooks/claude-hook.sh', 'echo\n')
        self.put('.config/orca/ai-vault/secret', 'x\n')
        self.put('.config/orcaneighbour/keep', 'x\n')
        self.put('Library/Application Support/orca/Cookies', 'x\n')

    def run_block(self):
        env = {'HOME': str(self.home), 'PATH': '/usr/bin:/bin'}
        return subprocess.run([BASH, '-euo', 'pipefail', '-c', BLOCK], env=env,
                              capture_output=True, text=True, check=True)

    def test_removes_every_orca_leftover_and_keeps_the_rest(self):
        self.seed()
        self.run_block()
        claude = self.json('.claude/settings.json')
        self.assertEqual(claude, {'model': 'opus[1m]', 'enabledPlugins': {'x@y': True}})
        self.assertFalse((self.home / '.codex/hooks.json').exists())
        config = (self.home / '.codex/config.toml').read_text()
        self.assertIn('# keep me', config)
        self.assertEqual(tomllib.loads(config), {
            'model': 'gpt',
            'hooks': {'state': {'/elsewhere/hooks.json:stop:0:0': {'trusted_hash': 'sha256:c'}}},
            'projects': {'/src/x': {'trust_level': 'trusted'}}})
        self.assertEqual(self.json('.gemini/config/hooks.json'), {'mine': {'Stop': [OTHER]}})
        self.assertFalse((self.home / '.orca').exists())
        self.assertFalse((self.home / '.config/orca').exists())
        self.assertTrue((self.home / '.config/orcaneighbour/keep').exists())
        self.assertEqual((self.home / 'Library/Application Support/orca').exists(), not MACOS)

    def test_keeps_other_hooks_and_status_line(self):
        mixed = {'matcher': 'Bash', 'hooks': [ORCA_CLAUDE, OTHER]}
        self.seed(claude=claude_settings(status=OTHER_STATUS, extra_group=mixed),
                  codex=codex_hooks(extra=OTHER))
        self.run_block()
        claude = self.json('.claude/settings.json')
        self.assertEqual(claude['hooks'], {'PreToolUse': [{'matcher': 'Bash', 'hooks': [OTHER]}]})
        self.assertEqual(claude['statusLine'], OTHER_STATUS)
        self.assertEqual(self.json('.codex/hooks.json'), {'hooks': {'Stop': [{'hooks': [OTHER]}]}})
        # The hooks file stays, so Codex keeps its trust state for it.
        self.assertEqual(len(tomllib.loads((self.home / '.codex/config.toml').read_text())['hooks']['state']), 3)

    def test_stale_trust_goes_once_the_hooks_file_is_gone(self):
        # An earlier run that deleted hooks.json but could not edit config.toml
        # leaves the trust entries behind; a later run must still drop them.
        self.seed()
        (self.home / '.codex/hooks.json').unlink()
        self.run_block()
        self.assertEqual(tomllib.loads((self.home / '.codex/config.toml').read_text())['hooks']['state'],
                         {'/elsewhere/hooks.json:stop:0:0': {'trusted_hash': 'sha256:c'}})

    def test_second_run_changes_nothing(self):
        self.seed(claude=claude_settings(status=OTHER_STATUS, extra_group={'hooks': [OTHER]}))
        self.run_block()
        files = [p for p in self.home.rglob('*') if p.is_file()]
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in files}
        result = self.run_block()
        self.assertEqual({p: (p.read_bytes(), p.stat().st_mtime_ns) for p in files}, before)
        self.assertEqual(result.stderr, '')

    def test_malformed_settings_are_left_alone(self):
        self.seed()
        broken = self.put('.claude/settings.json', '{"hooks": ')
        result = self.run_block()
        self.assertEqual(broken.read_text(), '{"hooks": ')
        self.assertIn('settings.json', result.stderr)
        self.assertFalse((self.home / '.orca').exists())

    def test_symlinked_state_directory_keeps_its_target(self):
        target = self.put('elsewhere/keep', 'x\n').parent
        (self.home / '.orca').symlink_to(target)
        self.run_block()
        self.assertFalse(os.path.lexists(self.home / '.orca'))
        self.assertTrue((target / 'keep').exists())

    def test_mode_is_kept(self):
        self.seed()
        settings = self.home / '.claude/settings.json'
        settings.chmod(0o600)
        self.run_block()
        self.assertEqual(settings.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main(argv=sys.argv[:1])
