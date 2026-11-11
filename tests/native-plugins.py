"""Run native plugin activation against recording CLI stubs.

usage: native-plugins.py SCRIPT PLUGINS_JSON [--agy-only]

PLUGINS_JSON lists the plugins the Antigravity CLI must install, in order, as
{"plugin": name, "source": path}. With --agy-only the script holds only the
Antigravity steps, so the Grok assertions are skipped.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

script = Path(sys.argv[1]).read_text()
plugins = json.loads(Path(sys.argv[2]).read_text())
agy_only = '--agy-only' in sys.argv[3:]
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    stub = home / 'native'
    stub.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
with open(os.environ['CALLS_' + os.path.basename(sys.argv[0]).upper()], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[-2:] == ['list', '--json']: print('[]')
''')
    stub.chmod(0o755)
    # One stub per CLI, so each CLI's calls land in their own log.
    for cli in ('grok', 'agy'):
        (home / cli).symlink_to(stub)
        script = re.sub(rf'/nix/store/[^\s]+/bin/{cli}\b', str(home / cli), script)
    env = dict(os.environ, HOME=str(home),
               CALLS_GROK=str(home / 'grok-calls'), CALLS_AGY=str(home / 'agy-calls'))
    env.pop('DRY_RUN', None)
    subprocess.run(['bash', '-eu', '-c', script], env=env, check=True)

    def recorded(name):
        log = home / f'{name}-calls'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    agy = recorded('agy')
    expected = [call for plugin in plugins for call in (
        ['plugin', 'validate', plugin['source']],
        ['plugin', 'install', plugin['source']],
        ['plugin', 'enable', plugin['plugin']],
    )]
    assert plugins, 'no plugins to install'
    assert agy == expected, (agy, expected)
    if not agy_only:
        grok = recorded('grok')
        assert any(call[:3] == ['plugin', 'install', '--trust'] for call in grok), grok
        assert ['plugin', 'enable', 'compound-engineering'] in grok, grok
