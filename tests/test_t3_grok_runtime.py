"""Check the pinned Grok's model input through an offline API fixture."""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, content, kind='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        self.reply(200, json.dumps({'object': 'list', 'data': [
            {'id': 'grok-4.7', 'object': 'model', 'owned_by': 'xai'},
        ]}).encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/responses':
            self.reply(404, b'')
            return
        data = json.loads(body)
        self.server.calls.append(data)
        chunks = [
            {'id': 'fixture', 'object': 'chat.completion.chunk', 'created': 0,
             'model': 'grok-4.7', 'choices': [{'index': 0, 'delta': {
                 'role': 'assistant', 'content': (
                     'The offline fixture checked the user task, shared baseline, current policy, '
                     'session continuation, and retained command arguments. All fixture steps completed. '
                 ) * 12}, 'finish_reason': None}]},
            {'id': 'fixture', 'object': 'chat.completion.chunk', 'created': 0,
             'model': 'grok-4.7', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]},
        ]
        events = ''.join('data: ' + json.dumps(chunk) + '\n\n' for chunk in chunks)
        self.reply(200, (events + 'data: [DONE]\n\n').encode(), 'text/event-stream')


class Runtime:
    def __init__(self, adapter, home, base):
        self.home = home
        self.errors = (home / 'runtime-stderr').open('w+')
        env = {'PATH': os.environ['PATH'], 'HOME': str(home),
               'GROK_HOME': str(home / '.grok'), 'XDG_CONFIG_HOME': str(home / '.config'),
               'LANG': 'en_US.UTF-8', 'XAI_API_KEY': 'fake-grok-test-key',
               'GROK_DISABLE_AUTOUPDATER': '1'}
        self.process = subprocess.Popen([
            adapter, 'agent', '--always-approve', '--no-leader',
            '--xai-api-base-url', base, '--cli-chat-proxy-base-url', base, 'stdio',
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            cwd=home, env=env, text=True)
        self.events = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.ident = 0

    def read(self):
        for line in self.process.stdout:
            self.events.put(json.loads(line))
        self.events.put(None)

    def request(self, method, params):
        self.ident += 1
        ident = self.ident
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': ident,
                                             'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        while True:
            response = self.events.get(timeout=25)
            assert response is not None, 'Grok closed the protocol before replying'
            if response.get('id') == ident and 'method' not in response:
                assert 'error' not in response, response
                return response['result']

    def initialize(self):
        result = self.request('initialize', {'protocolVersion': 1,
            'clientInfo': {'name': 'offline-fixture', 'version': '1'},
            'clientCapabilities': {}, '_meta': {'clientType': 'extension'}})
        assert result['agentCapabilities']['promptCapabilities']['embeddedContext'] is True
        self.request('authenticate', {'methodId': 'xai.api_key'})

    def close(self):
        if self.process.stdin.closed:
            return
        self.process.stdin.close()
        try:
            status = self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        finally:
            self.reader.join(timeout=2)
            self.process.stdout.close()
            self.errors.close()
        assert status == 0, f'Grok adapter exited {status}'


def verify(adapter):
    with tempfile.TemporaryDirectory(prefix='t3-grok-runtime-') as directory:
        home = Path(directory).resolve()
        baseline = home / '.grok/AGENTS.md'
        baseline.parent.mkdir()
        baseline.write_text('OFFLINE_BASELINE_MARKER\n')
        skill = home / '.grok/skills/offline-fixture/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('---\nname: offline-fixture\ndescription: Offline fixture skill\n---\nSKILL_CONTENT_MARKER: Reply OK and retain the supplied arguments.\n')
        policy = home / '.t3/userdata/instructions/grok.md'
        policy.parent.mkdir(parents=True)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Backend)
        server.calls = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        runtime = None
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            runtime = Runtime(adapter, home, base)
            runtime.initialize()
            sid = runtime.request('session/new', {'cwd': str(home), 'mcpServers': []})['sessionId']

            def task(marker, text=None):
                policy.write_text(marker + '\n')
                before = len(server.calls)
                query = text or f'Reply OK. QUERY_{before}'
                blocks = [{'type': 'text', 'text': query}]
                if text is None:
                    blocks.append({'type': 'text', 'text': 'T3_RUNTIME_CONTEXT_MARKER'})
                runtime.request('session/prompt', {'sessionId': sid, 'prompt': blocks})
                match = 'ARGUMENT_MARKER' if text else query
                candidates = []
                for call in server.calls[before:]:
                    messages = call.get('messages', [])
                    users = [m for m in messages if m.get('role') == 'user']
                    if users and match in str(users[-1].get('content', '')):
                        candidates.append(call)
                assert candidates, 'No model input contained the current user query'
                call = candidates[0]
                user = next(m for m in reversed(call['messages']) if m['role'] == 'user')
                content = str(user['content'])
                assert content.count(marker) == 1, 'Current policy missing or duplicated in task input'
                assert 't3-instructions://dotfiles/grok' in content
                if text is None:
                    assert 'T3_RUNTIME_CONTEXT_MARKER' in content
                else:
                    assert 'SKILL_CONTENT_MARKER' in content
                assert 'OFFLINE_BASELINE_MARKER' in json.dumps(call)

            task('FRESH_POLICY_MARKER')
            runtime.request('session/load', {'sessionId': sid, 'cwd': str(home), 'mcpServers': []})
            task('LOADED_POLICY_MARKER')
            runtime.request('session/resume', {'sessionId': sid, 'cwd': str(home), 'mcpServers': []})
            task('RESUMED_POLICY_MARKER')
            task('SKILL_POLICY_MARKER', '/offline-fixture ARGUMENT_MARKER')
            runtime.request('session/prompt', {'sessionId': sid, 'prompt': [
                {'type': 'text', 'text': '/context'}]})
            runtime.request('session/prompt', {'sessionId': sid, 'prompt': [
                {'type': 'text', 'text': '/compact'}]})
            task('AFTER_COMPACT_POLICY_MARKER')
            runtime.close()
            runtime = None
            runtime = Runtime(adapter, home, base)
            runtime.initialize()
            runtime.request('session/load', {'sessionId': sid, 'cwd': str(home), 'mcpServers': []})
            task('COLD_LOAD_POLICY_MARKER')
            assert baseline.read_text() == 'OFFLINE_BASELINE_MARKER\n'
        finally:
            try:
                if runtime is not None:
                    runtime.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    verify(sys.argv[1])
    print('Pinned Grok: fresh, loaded, resumed, cold-loaded, skill and post-compact task context passed.')
