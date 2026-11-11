"""Exercise native Pi reconciliation with inert credentials and unrelated state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    agent = Path(directory) / 'agent'
    shutil.copytree(sys.argv[1], agent, symlinks=False)
    # A copy of a store tree keeps its read-only modes.
    for path in [agent, *agent.rglob('*')]:
        path.chmod(path.stat().st_mode | 0o200)
    (agent / 'settings.json').write_text(json.dumps({'defaultProvider': 'foreign', 'defaultModel': 'bad',
        'packages': ['other'], 'extensions': ['other.ts'], 'ownerSetting': True}))
    (agent / 'auth.json').write_text('{"other":{"type":"api_key","key":"FAKE-other"}}')
    key = Path(directory) / 'key'
    key.write_text('FAKE-synthetic\n')
    plugin = Path(directory) / 'pinned-source'
    plugin.mkdir()
    (plugin / 'package.json').write_text(json.dumps({'name': 'compound-engineering', 'repository': 'https://github.com/EveryInc/compound-engineering-plugin'}))
    command = [sys.executable, sys.argv[2], '--agent', str(agent), '--plugin', str(plugin), '--key', str(key)]
    for _ in range(2):
        subprocess.run(command, check=True)
        settings = json.loads((agent / 'settings.json').read_text())
        assert settings['packages'] == ['other', str(plugin)]
        assert settings['extensions'] == ['other.ts', *[str(agent / name) for name in ('dotfiles-policy.ts', 'dotfiles-web.ts', 'dotfiles-question.ts')]]
        assert settings['ownerSetting'] is True
        ids = [model['id'] for model in json.loads((agent / 'model-lock.json').read_text())['syntheticModelLocks']['models']]
        assert settings['defaultProvider'] == 'synthetic' and settings['defaultModel'] in ids
        auth = json.loads((agent / 'auth.json').read_text())
        assert auth == {'other': {'type': 'api_key', 'key': 'FAKE-other'}, 'synthetic': {'type': 'api_key', 'key': 'FAKE-synthetic'}}
        assert (agent / 'auth.json').stat().st_mode & 0o777 == 0o600
    (agent / 'auth.json').write_text('[]')
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert (agent / 'auth.json').read_text() == '[]'
