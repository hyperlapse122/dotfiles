"""Run native plugin activation against recording CLI stubs."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]).read_text()
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    log = home / 'calls'
    stub = home / 'native'
    stub.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['CALLS'], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[-2:] == ['list', '--json']: print('[]')
''')
    stub.chmod(0o755)
    # Replace only native executables; retain the packaged Python reconciler.
    script = re.sub(r'/nix/store/[^\s]+/bin/(?:grok|agy)\b', str(stub), script)
    env = dict(os.environ, HOME=str(home), CALLS=str(log))
    env.pop('DRY_RUN', None)
    subprocess.run(['bash', '-eu', '-c', script], env=env, check=True)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert any(call[:3] == ['plugin', 'install', '--trust'] for call in calls), calls
    assert any(call[:2] == ['plugin', 'validate'] for call in calls), calls
    assert any(call[:2] == ['plugin', 'install'] and call[2] != '--trust' for call in calls), calls
    assert sum(call == ['plugin', 'enable', 'compound-engineering'] for call in calls) == 2, calls
