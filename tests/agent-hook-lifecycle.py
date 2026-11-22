"""Drive both pinned runtimes through edits and two turns on one session."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
from tempfile import TemporaryDirectory, TemporaryFile
from threading import Thread
import time


PROMPTS = ('Write the first fixture.', 'Write the second fixture.')
FOLLOW_UP = 'Run agent-check from the project root using your shell tool before finishing.'


@contextmanager
def model_server():
    requests = []

    class Model(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path != '/v1/chat/completions':
                self.send_error(404)
                return
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            messages = body['messages']
            last = json.dumps(messages[-1])
            if body.get('tools'):
                requests.append(last)
            if body.get('tools') and any(prompt in last for prompt in PROMPTS):
                number = 1 if PROMPTS[0] in last else 2
                call = {
                    'index': 0, 'id': f'call_write_{number}', 'type': 'function',
                    'function': {
                        'name': 'write',
                        'arguments': json.dumps({'path': f'fixture-{number}.py', 'content': 'eval(value)\n'}),
                    },
                }
                delta, reason = {'tool_calls': [call]}, 'tool_calls'
            else:
                delta, reason = {'content': 'Fixture complete.'}, 'stop'
            chunks = [
                {'choices': [{'index': 0, 'delta': {'role': 'assistant', **delta}, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': reason}]},
                {'choices': [], 'usage': {'prompt_tokens': 10, 'completion_tokens': 1, 'total_tokens': 11}},
            ]
            data = ''.join(f'data: {json.dumps({"id": "chatcmpl-fixture", "model": "fixture", **chunk})}\n\n'
                           for chunk in chunks) + 'data: [DONE]\n\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(data.encode())

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(('127.0.0.1', 0), Model) as server:
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            yield f'http://127.0.0.1:{server.server_port}/v1', requests
        finally:
            server.shutdown()
            thread.join()


@contextmanager
def session(command, cwd, env):
    with TemporaryFile() as errors, subprocess.Popen(
        command, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
    ) as process:
        pending = b''

        def send(message):
            process.stdin.write((json.dumps(message) + '\n').encode())
            process.stdin.flush()

        def until(predicate):
            nonlocal pending
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if line and predicate(event := json.loads(line)):
                        return event
                if select.select([process.stdout], [], [], 1)[0]:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    pending += chunk
            errors.seek(0)
            raise AssertionError(errors.read().decode(errors='replace'))

        try:
            yield send, until
        finally:
            process.stdin.close()


def pi_turns(executable, project, env, extension, url, assert_turn):
    agent = Path(env['HOME']) / 'pi'
    agent.mkdir()
    (agent / 'models.json').write_text(json.dumps({'providers': {'fixture': {
        'api': 'openai-completions', 'apiKey': 'fake-key', 'baseUrl': url,
        'models': [{'id': 'fixture', 'contextWindow': 65536, 'maxTokens': 4096}],
    }}}))
    command = [executable, '--offline', '--no-session', '--extension', extension,
               '--provider', 'fixture', '--model', 'fixture', '--mode', 'rpc']
    with session(command, project, dict(env, PI_CODING_AGENT_DIR=str(agent))) as (send, until):
        for number, prompt in enumerate(PROMPTS, 1):
            send({'id': str(number), 'type': 'prompt', 'message': prompt})
            result = until(lambda event: event.get('id') == str(number))
            assert result['success'], result
            until(lambda event: event.get('type') == 'agent_settled')
            assert_turn(number)


def opencode_turns(executable, project, env, extension, url, assert_turn):
    home = Path(env['HOME'])
    models = home / 'models.json'
    models.write_text('{}')
    config_home = Path(env['XDG_CONFIG_HOME']) / 'opencode'
    plugins = config_home / 'plugins'
    plugins.mkdir(parents=True)
    (plugins / 'dotfiles-agent-quality.ts').write_text(extension.read_text())
    config = config_home / 'opencode.json'
    config.write_text(json.dumps({
        'update': 'disable',
        'model': 'fixture/fixture',
        'providers': {'fixture': {
            'name': 'Fixture', 'package': 'aisdk:@ai-sdk/openai-compatible',
            'settings': {'apiKey': 'fake-key', 'baseURL': url},
            'models': {'fixture': {
                'name': 'Fixture', 'capabilities': {'tools': True, 'input': ['text'], 'output': ['text']},
                'limit': {'context': 65536, 'output': 4096},
            }},
        }},
    }))
    env = dict(env, OPENCODE_CONFIG=str(config), OPENCODE_MODELS_PATH=str(models),
               OPENCODE_DISABLE_AUTOUPDATE='true', OPENCODE_DISABLE_MODELS_FETCH='true')
    with session([executable, 'acp'], project, env) as (send, until):
        def request(identifier, method, **params):
            send({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params})

            def receive(message):
                if message.get('method') == 'session/request_permission':
                    option = next(opt for opt in message['params']['options'] if opt['kind'] == 'allow_once')
                    send({'jsonrpc': '2.0', 'id': message['id'], 'result': {
                        'outcome': {'outcome': 'selected', 'optionId': option['optionId']},
                    }})
                return message.get('id') == identifier and 'method' not in message

            response = until(receive)
            assert 'result' in response, response
            return response['result']

        request(0, 'initialize', protocolVersion=1, clientCapabilities={})
        session_id = request(1, 'session/new', cwd=str(project), mcpServers=[])['sessionId']
        for number, prompt in enumerate(PROMPTS, 1):
            result = request(number + 1, 'session/prompt', sessionId=session_id,
                             prompt=[{'type': 'text', 'text': prompt}])
            assert result['stopReason'] == 'end_turn', result
            assert_turn(number)


def exercise(turns, executable, rendered):
    with TemporaryDirectory() as directory, model_server() as (url, requests):
        home = Path(directory).resolve()
        project = home / 'checkout'
        project.mkdir()
        env = {key: os.environ[key] for key in ('PATH', 'TMPDIR', 'NIX_LD', 'NIX_LD_LIBRARY_PATH') if key in os.environ}
        env.update(HOME=str(home), XDG_CACHE_HOME=str(home / 'cache'), XDG_CONFIG_HOME=str(home / 'config'),
                   XDG_DATA_HOME=str(home / 'data'), XDG_STATE_HOME=str(home / 'state'))
        subprocess.run(['git', 'init', '-q', project], env=env, check=True)
        policy = home / 'policy.json'
        extension = home / 'quality.ts'
        source = Path(rendered).read_text()
        original_policy = Path(re.search(r'"/nix/store/[^"]+-agent-hook-policy\.json"', source)[0][1:-1])
        policy.write_text(json.dumps(dict(json.loads(original_policy.read_text()), trustedProjects=[str(project)])))
        extension.write_text(source.replace(str(original_policy), str(policy)))

        def assert_turn(number):
            turn = requests[(number - 1) * 3:]
            assert len(turn) == 3, turn
            first, tool_result, stop = turn
            assert PROMPTS[number - 1] in first, first
            assert 'eval_injection' in tool_result and f'fixture-{number}.py' in tool_result, tool_result
            assert FOLLOW_UP in stop, stop
            assert (project / f'fixture-{number}.py').read_text() == 'eval(value)\n'

        turns(executable, project, env, extension, url, assert_turn)


if __name__ == '__main__':
    harness, executable, extension = sys.argv[1:]
    exercise({'pi': pi_turns, 'opencode': opencode_turns}[harness], executable, extension)
