"""Drive the real Pi extension and one foreground child without network or credentials."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

pi, package, provider = sys.argv[1:]
start = 'Start the test parent.'


def child_result(events):
    result, = [event for event in events if event.get('type') == 'tool_execution_end'
               and event.get('toolName') == 'subagent']
    assert not result['isError'] and 'Test child marker.' in json.dumps(result['result']), result


def rpc(command, env, cwd, eligible):
    with subprocess.Popen([*command, '--mode', 'rpc'], cwd=cwd, env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        def send(request):
            process.stdin.write((json.dumps(request) + '\n').encode())
            process.stdin.flush()

        def events():
            deadline = time.monotonic() + 45
            pending = b''
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    yield json.loads(line)
                if select.select([process.stdout], [], [], 1)[0]:
                    data = os.read(process.stdout.fileno(), 65536)
                    assert data, process.stderr.read().decode()
                    pending += data
            raise AssertionError('Timed out waiting for Pi RPC')

        try:
            events = events()
            send({'id': 'commands', 'type': 'get_commands'})
            response = next(event for event in events if event.get('id') == 'commands')
            assert response['success'], response
            names = {command['name'] for command in response['data']['commands']}
            for name in ('subagents', 'skill:pi-subagents', 'parallel-research'):
                assert (name in names) == eligible, (name, env.get('T3_PI_RUNTIME_MODE'), names)
            if eligible:
                send({'id': 'prompt', 'type': 'prompt', 'message': start})
                result = []
                for event in events:
                    result.append(event)
                    if event.get('type') == 'agent_end':
                        break
                child_result(result)
        finally:
            process.kill()


with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    agent = home / 'agent'
    agent.mkdir()
    (agent / 'settings.json').write_text(json.dumps({'packages': [package], 'extensions': [provider]}))
    env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE='1')
    for key in ('T3_PI_RUNTIME_MODE', 'T3_PI_MCP_EXTENSION_PATH'):
        env.pop(key, None)
    command = [pi, '--offline', '--no-session', '--provider', 'subagents-test', '--model', 'test']
    cli = subprocess.run([*command, '--mode', 'json', '-p', start], cwd=home, env=env,
                         capture_output=True, text=True, timeout=45)
    assert cli.returncode == 0, cli.stderr
    child_result(map(json.loads, cli.stdout.splitlines()))

    rpc(command, env, home, False)
    rpc(command, dict(env, T3_PI_RUNTIME_MODE='full-access'), home, False)
    for mode in ('approval-required', 'auto-accept-edits', 'full-access'):
        rpc(command, dict(env, T3_PI_MCP_EXTENSION_PATH=provider, T3_PI_RUNTIME_MODE=mode),
            home, mode == 'full-access')
