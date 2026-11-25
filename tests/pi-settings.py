"""Run the Pi settings activation's pi-state call and check the models it selects."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

block, state, installed, agents = sys.argv[1], sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])
bash = sys.argv[5]

lines = [line for line in Path(block).read_text().splitlines() if '/bin/pi-state' in line and '--plugin' in line]
assert len(lines) == 1, lines
call = shlex.split(lines[0])
assert call[0].endswith('/bin/pi-state'), call

with tempfile.TemporaryDirectory() as directory:
    agent = Path(directory) / 'agent'
    agent.mkdir()
    shutil.copyfile(installed / 'models.json', agent / 'models.json')
    (agent / 'pi-subagents').symlink_to(installed / 'pi-subagents')
    plugin = Path(directory) / 'plugin'
    plugin.mkdir()
    call[0] = state
    subagents = agent / 'pi-subagents'
    assert Path(call[call.index('--subagents') + 1]) == Path(call[call.index('--agent') + 1]) / subagents.name
    call[call.index('--agent') + 1] = str(agent)
    call[call.index('--plugin') + 1] = str(plugin)
    call[call.index('--subagents') + 1] = str(subagents)
    settings_path = agent / 'settings.json'
    unrelated = {'source': 'npm:other', 'extensions': []}
    legacy = agent / 'old-subagents'
    legacy.mkdir()
    manifest = legacy / 'package.json'
    manifest.write_text(json.dumps({'name': 'pi-subagents',
        'repository': {'url': 'git+https://github.com/nicobailon/pi-subagents.git'}}))
    user_extension = 'user-extension.ts'
    quality_extension = str(agent / 'dotfiles-agent-quality.ts')
    assert (installed / Path(quality_extension).name).is_file()
    settings_path.write_text(json.dumps({
        'packages': [unrelated, 'npm:pi-subagents', {'source': 'npm:pi-subagents@0.80.0'},
                     str(legacy), str(installed / 'pi-subagents')],
        'extensions': [user_extension],
        'shellPath': '/old/bash',
        'compaction': {'reserveTokens': 20000, 'modelOverrides': {'other/model': {'reserveTokens': 123}}},
    }))
    for _ in range(2):
        subprocess.run([sys.executable, *call], check=True)
        settings = json.loads(settings_path.read_text())
        assert settings['shellPath'] == bash
        assert settings['packages'] == [unrelated, str(plugin), str(subagents)], settings['packages']
        assert json.loads((subagents / 'package.json').read_text())['name'] == 'pi-subagents'
        assert manifest.is_file()
        assert settings['extensions'][0] == user_extension
        assert settings['extensions'].count(quality_extension) == 1

    listed = [f'anthropic/{row["id"]}'
              for row in json.loads((agents / 'anthropic-models.json').read_text())['models']]
    selected = settings['enabledModels']
    assert settings['defaultProvider'] == 'synthetic'
    assert 'synthetic/' + settings['defaultModel'] in selected or 'synthetic/*' in selected
    local = json.loads((agent / 'models.json').read_text())['providers'].get('ollama')
    if local:
        model = local['models'][0]
        listed.append('ollama/' + model['id'])
        assert settings['compaction']['modelOverrides']['ollama/' + model['id']] == {
            'reserveTokens': 8192, 'keepRecentTokens': 8192}
    assert settings['compaction']['reserveTokens'] == 20000
    assert settings['compaction']['modelOverrides']['other/model'] == {'reserveTokens': 123}
    assert sorted(model for model in selected if not model.startswith('synthetic/')) == sorted(listed), selected

    subprocess.run([sys.executable, *[arg for arg in call if arg != '--quality']], check=True)
    settings = json.loads(settings_path.read_text())
    assert settings['extensions'][0] == user_extension
    assert quality_extension not in settings['extensions']
