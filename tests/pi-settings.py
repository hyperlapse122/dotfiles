"""Run the Pi settings activation's pi-state call and check the models it selects."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

block, state, installed, agents = sys.argv[1], sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])

lines = [line for line in Path(block).read_text().splitlines() if '/bin/pi-state' in line and '--plugin' in line]
assert len(lines) == 1, lines
call = shlex.split(lines[0])
assert call[0].endswith('/bin/pi-state'), call

with tempfile.TemporaryDirectory() as directory:
    agent = Path(directory) / 'agent'
    shutil.copytree(installed, agent, symlinks=False)
    for path in [agent, *agent.rglob('*')]:
        path.chmod(path.stat().st_mode | 0o200)
    plugin = Path(directory) / 'plugin'
    plugin.mkdir()
    call[0] = state
    call[call.index('--agent') + 1] = str(agent)
    call[call.index('--plugin') + 1] = str(plugin)
    subprocess.run([sys.executable, *call], check=True)

    listed = [f'{provider}/{row["id"]}'
              for provider in ('openai', 'anthropic')
              for row in json.loads((agents / f'{provider}-models.json').read_text())['models']]
    selected = json.loads((agent / 'settings.json').read_text())['enabledModels']
    assert sorted(model for model in selected if not model.startswith('synthetic/')) == sorted(listed), selected
