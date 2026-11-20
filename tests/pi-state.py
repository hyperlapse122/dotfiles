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
    shutil.copytree(sys.argv[1], agent, ignore=shutil.ignore_patterns('pi-subagents'))
    # A copy of a store tree keeps its read-only modes.
    for path in [agent, *agent.rglob('*')]:
        path.chmod(path.stat().st_mode | 0o200)
    hidden = 'syn:small:vision'
    (agent / 'settings.json').write_text(json.dumps({'defaultProvider': 'synthetic', 'defaultModel': hidden,
        'packages': ['other'], 'extensions': ['other.ts', str(agent / 'dotfiles-policy.ts')], 'ownerSetting': True}))
    (agent / 'auth.json').write_text('{"other":{"type":"api_key","key":"FAKE-other"}}')
    trust = '{"/remembered/project":true}'
    (agent / 'trust.json').write_text(trust)
    key = Path(directory) / 'key'
    key.write_text('FAKE-synthetic\n')
    openai = Path(directory) / 'openai-key'
    openai.write_text('FAKE-openai\n')
    anthropic = Path(directory) / 'anthropic-key'
    anthropic.write_text('FAKE-anthropic\n')
    plugin = Path(directory) / 'pinned-source'
    plugin.mkdir()
    (plugin / 'package.json').write_text(json.dumps({'name': 'compound-engineering', 'repository': 'https://github.com/EveryInc/compound-engineering-plugin'}))
    command = [sys.executable, sys.argv[2], '--agent', str(agent), '--plugin', str(plugin),
               '--key', str(key), '--credential', f'openai={openai}', '--credential', f'anthropic={anthropic}',
               '--hide-model', f'synthetic/{hidden}', '--model', 'openai/model-one', '--model', 'anthropic/model-two']
    for _ in range(2):
        subprocess.run(command, check=True)
        settings = json.loads((agent / 'settings.json').read_text())
        assert settings['packages'] == ['other', str(plugin)]
        # The retired policy extension is dropped, and the managed ones follow the user's own.
        assert settings['extensions'] == ['other.ts', *[str(agent / name) for name in ('dotfiles-web.ts', 'dotfiles-question.ts')]]
        assert settings['ownerSetting'] is True
        assert settings['defaultProjectTrust'] == 'ask'
        assert (agent / 'trust.json').read_text() == trust
        ids = [model['id'] for model in json.loads((agent / 'models.json').read_text())['providers']['synthetic']['models']]
        assert hidden in ids
        assert settings['defaultProvider'] == 'synthetic' and settings['defaultModel'] == min(set(ids) - {hidden})
        assert settings['enabledModels'] == [f'synthetic/{model}' for model in ids if model != hidden] + ['openai/model-one', 'anthropic/model-two']
        assert not (agent / 'model-lock.json').exists() and not (agent / 'dotfiles-policy.ts').exists()
        auth = json.loads((agent / 'auth.json').read_text())
        assert auth == {'other': {'type': 'api_key', 'key': 'FAKE-other'}, 'synthetic': {'type': 'api_key', 'key': 'FAKE-synthetic'},
                        'openai': {'type': 'api_key', 'key': 'FAKE-openai'}, 'anthropic': {'type': 'api_key', 'key': 'FAKE-anthropic'}}
        assert (agent / 'auth.json').stat().st_mode & 0o777 == 0o600
    subprocess.run(['node', sys.argv[4], sys.argv[3], str(agent)], check=True)

    plain = [sys.executable, sys.argv[2], '--agent', str(agent), '--plugin', str(plugin)]
    subprocess.run(plain, check=True)
    assert json.loads((agent / 'settings.json').read_text())['enabledModels'] == ['synthetic/*']

    openai.unlink()
    anthropic.write_text('FAKE-anthropic-rotated\n')
    subprocess.run([sys.executable, sys.argv[2], '--agent', str(agent), '--auth-only', '--key', str(key),
                    '--credential', f'openai={openai}', '--credential', f'anthropic={anthropic}'], check=True)
    auth = json.loads((agent / 'auth.json').read_text())
    assert auth['openai'] == {'type': 'api_key', 'key': 'FAKE-openai'}
    assert auth['anthropic'] == {'type': 'api_key', 'key': 'FAKE-anthropic-rotated'}
    assert auth['other'] == {'type': 'api_key', 'key': 'FAKE-other'}

    before = (agent / 'auth.json').read_text()
    for invalid in ('', 'two\nlines\n'):
        anthropic.write_text(invalid)
        failed = subprocess.run([sys.executable, sys.argv[2], '--agent', str(agent), '--auth-only', '--key', str(key),
                                 '--credential', f'anthropic={anthropic}'], capture_output=True)
        assert failed.returncode != 0
        assert (agent / 'auth.json').read_text() == before
    for malformed in ('openai', '=file', 'open/ai=file'):
        failed = subprocess.run([sys.executable, sys.argv[2], '--agent', str(agent), '--auth-only', '--key', str(key),
                                 '--credential', malformed], capture_output=True)
        assert failed.returncode != 0, malformed
        assert (agent / 'auth.json').read_text() == before
    key.write_text('FAKE-synthetic-rotated\n')
    anthropic.write_text('FAKE-anthropic-rotated\n')
    subprocess.run([sys.executable, sys.argv[2], '--agent', str(agent), '--auth-only', '--key', str(key),
                    '--credential', f'anthropic={anthropic}'], check=True)
    assert json.loads((agent / 'auth.json').read_text())['synthetic'] == {'type': 'api_key', 'key': 'FAKE-synthetic-rotated'}

    (agent / 'auth.json').write_text('[]')
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert (agent / 'auth.json').read_text() == '[]'
