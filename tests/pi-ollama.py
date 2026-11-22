"""Exercise local inference and failure through the installed Pi wrapper."""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

wrapper, installed, key_directory = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append((self.path, body))
        if not self.path.startswith('/local/'):
            self.send_response(503)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        if len(requests) == 1:
            delta = {'tool_calls': [{'index': 0, 'id': 'call_1', 'type': 'function',
                                     'function': {'name': 'read', 'arguments': '{"path":"fixture.txt"}'}}]}
            finish = 'tool_calls'
        else:
            delta = {'content': 'Local tool round trip complete.'}
            finish = 'stop'
        for item in (delta, {}):
            event = {'id': 'chatcmpl-test', 'object': 'chat.completion.chunk', 'created': 1,
                     'model': body['model'], 'choices': [{'index': 0, 'delta': item,
                     'finish_reason': finish if not item else None}]}
            self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n')


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
cloud = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
cloud_thread = threading.Thread(target=cloud.serve_forever, daemon=True)
cloud_thread.start()
try:
    with tempfile.TemporaryDirectory() as directory:
        home = Path(directory)
        agent = home / '.pi/agent'
        shutil.copytree(installed, agent, ignore=shutil.ignore_patterns('pi-subagents'))
        for path in [agent, *agent.rglob('*')]:
            path.chmod(path.stat().st_mode | 0o200)
        models = json.loads((agent / 'models.json').read_text())
        local = models['providers'].get('ollama')
        if local is None:
            sys.exit(0)
        endpoint = f'http://127.0.0.1:{server.server_port}'
        cloud_endpoint = f'http://127.0.0.1:{cloud.server_port}'
        local['baseUrl'] = endpoint + '/local/v1'
        for provider in ('synthetic', 'openai', 'anthropic'):
            models['providers'][provider]['baseUrl'] = cloud_endpoint + '/cloud/' + provider
        (agent / 'models.json').write_text(json.dumps(models))
        auth = {provider: {'type': 'api_key', 'key': 'FAKE'} for provider in ('openai', 'anthropic')}
        (agent / 'auth.json').write_text(json.dumps(auth))
        (home / 'fixture.txt').write_text('safe local fixture\n')
        executable = home / 'pi'
        contents = wrapper.read_text()
        for name in ('synthetic', 'openai', 'anthropic', 'exa'):
            contents = contents.replace(f'{key_directory}/{name}_api_key', str(home / (name + '-missing')))
        executable.write_text(contents)
        executable.chmod(0o700)
        env = dict(PATH=os.environ['PATH'], HOME=directory, PI_CODING_AGENT_DIR=str(agent),
                   HTTP_PROXY=cloud_endpoint, HTTPS_PROXY=cloud_endpoint, http_proxy=cloud_endpoint, https_proxy=cloud_endpoint,
                   NO_PROXY='example.invalid', no_proxy='example.invalid')
        command = [str(executable), '--offline', '--no-extensions', '--no-session', '--print',
                   '--provider', 'ollama', '--model', local['models'][0]['id'], 'Read fixture.txt.']
        result = subprocess.run(command, cwd=home, env=env, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            listing = subprocess.run([str(executable), '--offline', '--provider', 'ollama', '--model', local['models'][0]['id'], '--list-models'], cwd=home, env=env,
                                     capture_output=True, text=True, timeout=30)
            raise AssertionError((result.stdout, result.stderr, listing.stderr))
        assert 'Local tool round trip complete.' in result.stdout, (result.stdout, result.stderr)
        assert len(requests) == 2 and all(path == '/local/v1/chat/completions' for path, _ in requests), requests
        assert all(body.get('max_tokens') == 4096 and 'max_completion_tokens' not in body for _, body in requests), requests
        assert any(message.get('role') == 'tool' and 'safe local fixture' in str(message.get('content'))
                   for message in requests[1][1]['messages']), requests[1]
        auth['synthetic'] = {'type': 'api_key', 'key': 'FAKE'}
        (agent / 'auth.json').write_text(json.dumps(auth))
        requests.clear()
        server.shutdown()
        server.server_close()
        thread.join()
        result = subprocess.run(command, cwd=home, env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode != 0 or 'error' in (result.stdout + result.stderr).lower(), (result.stdout, result.stderr)
        assert not requests, requests
        # Missing Synthetic credentials remain an error for ordinary sessions.
        ordinary = subprocess.run([str(executable), '--offline', '--no-session', '--print', 'test'],
                                  cwd=home, env=env, capture_output=True, text=True, timeout=30)
        assert ordinary.returncode != 0, ordinary.stdout
        for selection in (['--provider', 'ollama'], ['--provider', 'ollama', '--model', 'synthetic/test']):
            result = subprocess.run([str(executable), '--offline', '--no-session', '--print', *selection, 'test'],
                                    cwd=home, env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode != 0 and 'Cannot reconcile Pi state' in result.stderr, result.stderr
finally:
    if thread.is_alive():
        server.shutdown()
        server.server_close()
        thread.join()
    cloud.shutdown()
    cloud.server_close()
    cloud_thread.join()
