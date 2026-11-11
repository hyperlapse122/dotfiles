#!/usr/bin/env python3
"""T3 Code's Antigravity instance and the sign-in link that serves run homes.

Run by tests/t3code-traits.nix in two modes:

  t3code-antigravity-instance.py instance MERGER DECLARED
  t3code-antigravity-instance.py signin ACTIVATION_SCRIPT HOME

instance merges the declared document with the real merger. The declaration
sets the driver, the enabled flag and config.binaryPath of the antigravity
instance and keeps every sibling key the owner set, on a second merge too.

signin executes the materialized activation block in a scratch home. The
standard home's token path becomes a link to T3 Code's instance token, which
lives under a directory named by the sha256 of the instance id; a sign-in file
that is a regular file stays and draws one warning.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WRAPPER = '/bin/agy_acp_server.par'


def merge(merger, declared, target, ledger):
    subprocess.run([merger, '--settings', str(target), '--declared', declared,
                    '--ledger', str(ledger)], check=True)
    instances = json.loads(target.read_text())['providerInstances']
    assert 'antigravity' in instances, 'the merge declares no antigravity instance'
    return instances['antigravity']


def instance(merger, declared):
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        target = scratch / 'settings.json'
        ledger = scratch / 'ledger.json'

        # An instance with no declared entry is created with the three leaves.
        target.write_text(json.dumps({'providerInstances': {}}))
        for _ in range(2):
            created = merge(merger, declared, target, ledger)
            assert created.get('driver') == 'antigravity', created
            assert created.get('enabled') is True, created
            assert created.get('config', {}).get('binaryPath', '').endswith(WRAPPER), created
            assert set(created) == {'driver', 'enabled', 'config'}, created
            assert set(created['config']) == {'binaryPath'}, created
        binary_path = created['config']['binaryPath']

        # The owner's disabled flag and runtime path give way; a sibling stays.
        target.write_text(json.dumps({'providerInstances': {'antigravity': {
            'driver': 'antigravity', 'enabled': False,
            'config': {'binaryPath': '/user/runtime', 'other': True}, 'custom': 'kept'}}}))
        for _ in range(2):
            merged = merge(merger, declared, target, ledger)
            assert merged.get('driver') == 'antigravity', merged
            assert merged.get('enabled') is True, merged
            assert merged['config'].get('binaryPath') == binary_path, merged
            assert merged['config'].get('other') is True, merged
            assert merged.get('custom') == 'kept', merged


def signin(script_path, original_home):
    script = Path(script_path).read_text()
    digest = hashlib.sha256(b'antigravity').hexdigest()
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        home = scratch / 'home'
        home.mkdir()
        redirected = script.replace(original_home, str(home))
        assert redirected != script, 'the activation does not target the home directory'
        block = scratch / 'block.sh'
        block.write_text(redirected)
        env = dict(os.environ, HOME=str(home))
        env.pop('DRY_RUN', None)
        standard = home / '.gemini/antigravity-acp'
        token = standard / 'acp_token.json'
        instance_token = home / '.t3/userdata/providers/antigravity' / digest / 'antigravity-acp/acp_token.json'

        def activate(**extra):
            result = subprocess.run(['bash', '-euo', 'pipefail', str(block)], env=dict(env, **extra),
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            return result.stdout + result.stderr

        activate(DRY_RUN='1')
        assert not (home / '.gemini').exists(), 'a dry run created state'

        activate()
        assert token.is_symlink(), 'the token path is not a link'
        assert Path(os.readlink(token)) == instance_token, os.readlink(token)
        assert (standard.stat().st_mode & 0o777) == 0o700, oct(standard.stat().st_mode)

        activate()
        assert sorted(path.name for path in standard.iterdir()) == ['acp_token.json']
        assert Path(os.readlink(token)) == instance_token

        # A stale link is refreshed, and a sign-in made later is reachable
        # through the link without the activation touching it.
        token.unlink()
        token.symlink_to(scratch / 'elsewhere')
        activate()
        assert Path(os.readlink(token)) == instance_token, os.readlink(token)
        instance_token.parent.mkdir(parents=True)
        instance_token.write_text('{"refresh_token": "fake-instance-token"}')
        activate()
        assert instance_token.read_text() == '{"refresh_token": "fake-instance-token"}'
        copy = scratch / 'copy.json'
        shutil.copyfile(token, copy)
        assert copy.read_text() == instance_token.read_text(), 'a copy through the link lacks the instance token'

        # A regular file is the owner's own sign-in: it stays, with one warning.
        token.unlink()
        token.write_text('{"refresh_token": "fake-own-token"}')
        output = activate()
        assert not token.is_symlink() and token.read_text() == '{"refresh_token": "fake-own-token"}'
        lines = [line for line in output.splitlines() if line.strip()]
        assert len(lines) == 1 and str(token) in lines[0] and 'not shared with T3 Code' in lines[0], output
        assert 'fake-own-token' not in output and 'fake-instance-token' not in output


def main():
    mode, first, second = sys.argv[1:4]
    {'instance': instance, 'signin': signin}[mode](first, second)


if __name__ == '__main__':
    main()
