"""Probe provider registration in the packaged Pi runtime without network access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    agent = Path(directory)
    for name in ('dotfiles-policy.ts', 'model-lock.json', 'models.json'):
        shutil.copyfile(Path(sys.argv[2]) / name, agent / name)
    configured = json.loads((agent / 'models.json').read_text())
    extra = dict(configured['providers']['synthetic']['models'][0], id='unlocked-model')
    configured['providers']['synthetic']['models'].append(extra)
    configured['providers']['foreign'] = dict(configured['providers']['synthetic'], models=[extra])
    (agent / 'models.json').write_text(json.dumps(configured))
    (agent / 'auth.json').write_text(json.dumps({
        provider: {'type': 'api_key', 'key': 'FAKE'} for provider in ('synthetic', 'foreign')
    }))
    env = dict(os.environ, HOME=directory, PI_CODING_AGENT_DIR=directory, PI_OFFLINE='1')
    result = subprocess.run([sys.argv[1], '--offline', '--no-extensions', '--extension',
                             str(agent / 'dotfiles-policy.ts'), '--list-models'],
                            env=env, capture_output=True, text=True, check=True)
    assert not result.stderr.strip(), result.stderr
    rows = [line.split()[:2] for line in result.stdout.splitlines()[1:] if line.strip()]
    expected = json.loads((agent / 'model-lock.json').read_text())['syntheticModelLocks']['models']
    assert sorted(rows) == sorted([['synthetic', model['id']] for model in expected]), result.stdout
