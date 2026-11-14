"""Exercise the installed ACP adapter through a recording Grok on PATH."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest


ADAPTER = str(Path(sys.argv.pop(1)).resolve())
URI = 't3-instructions://dotfiles/grok'
PEER = '''import json, os, sys
if 'agent' not in sys.argv or 'stdio' not in sys.argv:
    print(json.dumps({'argv': sys.argv[1:], 'home': os.environ['HOME'], 'cwd': os.getcwd()}))
    print('peer stderr', file=sys.stderr)
    sys.exit(23)
print('peer stderr', file=sys.stderr, flush=True)
for line in sys.stdin.buffer:
    message = json.loads(line)
    if message.get('method') == 'fixture/exit':
        print('peer exit', flush=True)
        sys.exit(message['params'])
    sys.stdout.buffer.write(line)
    sys.stdout.buffer.flush()
'''


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name).resolve()
        self.policy = self.home / '.t3/userdata/instructions/grok.md'
        self.policy.parent.mkdir(parents=True)
        self.policy.write_text('Current T3 policy 한글\n')
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        peer = self.bin / 'grok'
        peer.write_text('#!' + sys.executable + '\n' + PEER)
        peer.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.environ['PATH'])

    def launch(self, arguments=None):
        process = subprocess.Popen([sys.executable, ADAPTER, *(arguments or ['agent', 'stdio'])],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   cwd=self.home, env=self.env)
        self.addCleanup(self.close, process)
        return process

    def close(self, process):
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()

    def exchange(self, process, message, fragmented=False):
        encoded = json.dumps(message, ensure_ascii=False).encode() + b'\n'
        if fragmented:
            for part in (encoded[:7], encoded[7:19], encoded[19:]):
                process.stdin.write(part)
                process.stdin.flush()
        else:
            process.stdin.write(encoded)
            process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(5), 'peer did not receive the request')
        return json.loads(process.stdout.readline())

    def test_prompt_context_and_transparent_messages(self):
        process = self.launch(['--permission-mode', 'default', 'agent', 'stdio'])
        for message in (
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'_meta': {'clientType': 'extension'}}},
            *({'id': 2, 'method': method, 'params': {'cwd': '/work', 'sessionId': 'existing', 'mcpServers': []}}
              for method in ('session/new', 'session/load', 'session/resume')),
            {'id': 'approval', 'result': {'outcome': {'outcome': 'selected', 'optionId': 'allow'}}},
            {'method': 'session/cancel', 'params': {'sessionId': 'existing'}},
            {'method': 'unknown/notification', 'params': {'keep': True}},
        ):
            self.assertEqual(self.exchange(process, message), message)
        original = [{'type': 'text', 'text': '/skill keep arguments'},
                    {'type': 'text', 'text': '<t3_code_instructions>Keep T3 instructions.</t3_code_instructions>'},
                    {'type': 'image', 'data': 'AA==', 'mimeType': 'image/png'},
                    {'type': 'resource', 'resource': {'uri': 'file:///keep.md', 'text': 'User attachment'}}]
        prompt = {'jsonrpc': '2.0', 'id': 8, 'method': 'session/prompt',
                  'params': {'sessionId': 'existing', '_meta': {'keep': '한글'}, 'prompt': original}}
        result = self.exchange(process, prompt, fragmented=True)
        self.assertEqual(result['params']['prompt'][:-1], original)
        self.assertEqual(result['params']['prompt'][-1], {'type': 'resource', 'resource': {
            'uri': URI, 'mimeType': 'text/markdown', 'text': 'Current T3 policy 한글\n'}})
        self.assertEqual(result['params']['sessionId'], 'existing')
        self.assertEqual(result['params']['_meta'], {'keep': '한글'})
        self.assertEqual(result['id'], 8)
        self.policy.write_text('Refreshed policy\n')
        refreshed = self.exchange(process, result)
        self.assertEqual(refreshed['params']['prompt'][:-1], original)
        self.assertEqual(refreshed['params']['prompt'][-1]['resource']['text'], 'Refreshed policy\n')
        self.assertEqual(sum(b.get('resource', {}).get('uri') == URI
                             for b in refreshed['params']['prompt']), 1)

    def test_missing_or_empty_policy_stops_task_before_forwarding(self):
        for value in (None, '', '  '):
            with self.subTest(value=value):
                if value is None:
                    self.policy.unlink(missing_ok=True)
                else:
                    self.policy.write_text(value)
                process = self.launch()
                request = {'id': 1, 'method': 'session/prompt', 'params': {'prompt': [
                    {'type': 'text', 'text': 'PRIVATE_TASK_CONTENT'}]}}
                output, error = process.communicate(json.dumps(request).encode() + b'\n', timeout=5)
                self.assertEqual(process.returncode, 1)
                self.assertEqual(output, b'')
                self.assertIn(b'T3 Grok instruction delivery failed.', error)
                self.assertNotIn(b'PRIVATE_TASK_CONTENT', error)

    def test_non_agent_calls_keep_arguments_environment_and_exit(self):
        self.policy.unlink()
        process = self.launch(['--version', 'quoted argument'])
        output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 23)
        self.assertEqual(json.loads(output), {'argv': ['--version', 'quoted argument'],
                                             'home': str(self.home), 'cwd': str(self.home)})
        self.assertEqual(error, b'peer stderr\n')

    def test_peer_exit_does_not_wait_for_open_client_stdin(self):
        process = self.launch()
        process.stdin.write(b'{"method":"fixture/exit","params":19}\n')
        process.stdin.flush()
        self.assertEqual(process.wait(timeout=5), 19)
        self.assertEqual(process.stdout.read(), b'peer exit\n')

    def test_signals_reach_peer(self):
        process = self.launch(['agent', '--always-approve', 'stdio'])
        self.exchange(process, {'method': 'ready'})
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)

    def test_large_input_and_output_can_overlap(self):
        (self.bin / 'grok').write_text('#!' + sys.executable + '\n' + '''import json, sys
first = sys.stdin.buffer.read(1)
print(json.dumps({'method': 'session/update', 'params': {'text': 'N' * 1048576}}), flush=True)
sys.stdout.buffer.write(first + sys.stdin.buffer.readline())
sys.stdout.buffer.flush()
''')
        process = subprocess.Popen([sys.executable, ADAPTER, 'agent', 'stdio'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   cwd=self.home, env=self.env, start_new_session=True)
        original = {'type': 'image', 'data': 'A' * 1048576, 'mimeType': 'image/png'}
        request = {'method': 'session/prompt', 'params': {'prompt': [original]}}
        try:
            output, error = process.communicate(json.dumps(request).encode() + b'\n', timeout=5)
            self.assertEqual(process.returncode, 0, error)
            notification, forwarded = map(json.loads, output.splitlines())
            self.assertEqual(len(notification['params']['text']), 1048576)
            self.assertEqual(forwarded['params']['prompt'][0], original)
            self.assertEqual(forwarded['params']['prompt'][1]['resource']['uri'], URI)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()


if __name__ == '__main__':
    unittest.main()
