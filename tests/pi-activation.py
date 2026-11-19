"""Run the real Pi credential activation block in a scratch home with fake published keys."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

block_path, original_home, original_keys, lock = sys.argv[1:]
script = Path(block_path).read_text()
assert original_keys in script and original_home in script, 'activation does not name the published keys or the home'

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    home = root / 'home'
    keys = root / 'keys'
    agent = home / '.pi/agent'
    agent.mkdir(parents=True)
    keys.mkdir()
    shutil.copyfile(lock, agent / 'model-lock.json')
    for name, value in [('synthetic', 'FAKE-synthetic'), ('openai', 'FAKE-openai'), ('anthropic', 'FAKE-anthropic')]:
        (keys / f'{name}_api_key').write_text(value + '\n')
    (agent / 'auth.json').write_text(json.dumps({'other': {'type': 'api_key', 'key': 'FAKE-other'}}))

    # The key directory can sit inside the home, so replace it first.
    redirected = script.replace(original_keys, str(keys)).replace(original_home, str(home))
    assert original_keys not in redirected and original_home not in redirected
    block = root / 'block.sh'
    block.write_text(redirected)
    env = dict(os.environ, HOME=str(home))
    env.pop('DRY_RUN', None)

    def run(**extra):
        return subprocess.run(['bash', '-euo', 'pipefail', str(block)], env=dict(env, **extra), cwd=home,
                              capture_output=True, text=True)

    before = (agent / 'auth.json').read_text()
    assert run(DRY_RUN='1').returncode == 0
    assert (agent / 'auth.json').read_text() == before, 'a dry run wrote credentials'

    result = run()
    assert result.returncode == 0, result.stderr
    auth = json.loads((agent / 'auth.json').read_text())
    assert auth == {
        'other': {'type': 'api_key', 'key': 'FAKE-other'},
        'synthetic': {'type': 'api_key', 'key': 'FAKE-synthetic'},
        'openai': {'type': 'api_key', 'key': 'FAKE-openai'},
        'anthropic': {'type': 'api_key', 'key': 'FAKE-anthropic'},
    }, auth
    assert (agent / 'auth.json').stat().st_mode & 0o777 == 0o600

    # A host that publishes no OpenAI key keeps its other credentials in place.
    (keys / 'openai_api_key').unlink()
    (keys / 'anthropic_api_key').write_text('FAKE-anthropic-rotated\n')
    assert run().returncode == 0
    auth = json.loads((agent / 'auth.json').read_text())
    assert auth['openai'] == {'type': 'api_key', 'key': 'FAKE-openai'}
    assert auth['anthropic'] == {'type': 'api_key', 'key': 'FAKE-anthropic-rotated'}
