import asyncio
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import socket
import signal
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from aiohttp import ClientSession, UnixConnector, web

source = Path(__file__).resolve().parents[1] / 'packages' / 'decide'
if source.exists():
    sys.path.insert(0, str(source))
from decide.core import DecisionError, Judge, error
from decide import cli
from decide.mlx import MLX, REVISION
from decide.server import Service
from decide.openrouter import OpenRouter

REQUEST = {'model': 'test/model', 'state': 'hello', 'questions': {
    'yes': {'type': 'noul', 'instructions': 'ready?'},
    'choice': {'type': 'choice', 'criteria': {'a': 'yes', 'b': 'no'}},
    'score': {'type': 'score', 'criteria': ['low', 'high']}}}
RESPONSE = {'model': 'test/model', 'answers': {
    'yes': {'type': 'noul', 'noul': 0.8}, 'choice': {'type': 'refusal', 'reason': 'unavailable'},
    'score': {'type': 'score', 'score': 0.5}}, 'usage': {'input_tokens': 1, 'output_tokens': 0}}


class Backend:
    def __init__(self):
        self.active = 0
        self.max_active = 0
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.last_request = None
        self.requests = []

    async def judge(self, request, *, headers=None):
        self.last_request = request
        self.requests.append(request)
        self.active += 1
        self.max_active = max(self.max_active, self.active)
        try:
            if request['state'] == 'wait':
                self.started.set()
                await self.release.wait()
            if request['state'] == 'fail':
                raise error(401, 'OpenRouter credential is unavailable')
            if request['state'] == 'quota':
                raise DecisionError(429, {'error': {'code': 429, 'message': 'quota exceeded', 'metadata': {'provider': 'remote'}}})
            if request['state'] == 'unexpected':
                raise ValueError('secret request contents')
            return RESPONSE
        finally:
            self.active -= 1


class IPC(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.socket = str(Path(self.temp.name) / 'service.sock')
        self.backend = Backend()
        self.service = Service(Judge(self.backend), self.socket)
        await self.service.start()
        self.client = ClientSession(connector=UnixConnector(path=self.socket))

    async def asyncTearDown(self):
        self.backend.release.set()
        await self.client.close()
        await self.service.close()
        self.temp.cleanup()

    async def post(self, data):
        async with self.client.post('http://localhost/api/alpha/decisions', json=data) as response:
            return response.status, await response.json()

    async def cli(self, *args, input=None):
        executable = os.environ.get('DECIDE_TEST_CLI')
        command = [executable] if executable else [sys.executable, '-m', 'decide']
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(sys.path))
        process = await asyncio.create_subprocess_exec(*command, *args, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, stdin=asyncio.subprocess.PIPE, env=env)
        out, err = await process.communicate(input)
        return process.returncode, out.decode(), err.decode()

    async def test_independent_client_and_human_cli(self):
        status, body = await self.post(REQUEST)
        self.assertEqual((status, body), (200, RESPONSE))
        code, out, err = await self.cli('judge', '--socket', self.socket, '--json', '-', input=json.dumps(REQUEST).encode())
        self.assertEqual((code, json.loads(out)), (0, RESPONSE), err)
        code, out, err = await self.cli('judge', '--socket', self.socket, '-', input=json.dumps(REQUEST).encode())
        self.assertEqual(code, 0, err)
        self.assertIn('refusal', out.lower())
        self.assertIn('0.8', out)
        config = Path(self.temp.name) / 'config.toml'
        config.write_text('model = "configured/model"\n')
        without_model = {key: value for key, value in REQUEST.items() if key != 'model'}
        code, _, err = await self.cli('judge', '--config', str(config), '--socket', self.socket, '-', input=json.dumps(without_model).encode())
        self.assertEqual(code, 0, err)
        self.assertEqual(self.backend.last_request['model'], 'configured/model')
        code, _, err = await self.cli('judge', '--model', 'override/model', '--socket', self.socket,
                                      '-', input=json.dumps(REQUEST).encode())
        self.assertEqual(code, 0, err)
        self.assertEqual(self.backend.last_request['model'], 'override/model')
        failed = dict(REQUEST, state='fail')
        status, body = await self.post(failed)
        self.assertEqual((status, body['error']['code']), (401, 401))
        code, out, err = await self.cli('judge', '--socket', self.socket, '-', input=json.dumps(failed).encode())
        self.assertNotEqual(code, 0)
        self.assertIn('credential', err.lower())
        self.assertNotIn('hello', err)
        self.assertEqual(out, '')
        quota = dict(REQUEST, state='quota')
        self.assertEqual(await self.post(quota), (429, {'error': {'code': 429, 'message': 'quota exceeded', 'metadata': {'provider': 'remote'}}}))
        code, _, err = await self.cli('judge', '--socket', self.socket, '-', input=json.dumps(quota).encode())
        self.assertNotEqual(code, 0)
        self.assertIn('quota exceeded', err)
        code, out, err = await self.cli('judge', '--socket', self.socket, '--json', '-',
                                      input=json.dumps(quota).encode())
        self.assertNotEqual(code, 0)
        self.assertEqual(json.loads(err), {'error': {'code': 429, 'message': 'quota exceeded',
                                                   'metadata': {'provider': 'remote'}}})
        self.assertEqual(out, '')

    async def test_large_request(self):
        status, body = await self.post(dict(REQUEST, state='x' * (1024 * 1024 + 1)))
        self.assertEqual((status, body), (200, RESPONSE))

    async def test_service_info_observes_local_head_without_loading(self):
        calls = []

        class TestMLX(MLX):
            def _load(self):
                calls.append('load')
                return object()

            def _infer(self, record):
                calls.append('infer')
                return dict(RESPONSE, model=record['model'])

        await self.service.close()
        self.service = Service(Judge(TestMLX('/unused')), self.socket)
        await self.service.start()

        async def info():
            async with self.client.get('http://localhost/info') as response:
                self.assertEqual(response.status, 200)
                return await response.json()

        expected = {'backend': 'mlx', 'local_model': {
            'id': MLX.model, 'revision': REVISION, 'load_state': 'unloaded'}}
        self.assertEqual(await info(), expected)
        self.assertEqual(calls, [])
        self.assertEqual((await self.post(dict(REQUEST, model=MLX.model)))[0], 200)
        expected['local_model']['load_state'] = 'loaded'
        self.assertEqual(await info(), expected)
        self.assertEqual(calls, ['load', 'infer'])

    async def test_info_cli_reports_selected_and_local_models(self):
        class StatusMLX(MLX):
            def status(self):
                return dict(super().status(), model='daemon/default', backend_source='package')

        await self.service.close()
        self.service = Service(Judge(StatusMLX('/unused')), self.socket)
        await self.service.start()
        config = Path(self.temp.name) / 'config.toml'
        config.write_text(f'model = "{MLX.model}"\n')
        args = ('info', '--config', str(config), '--socket', self.socket)

        code, out, err = await self.cli(*args)
        self.assertEqual(code, 0, err)
        for value in ('mlx', MLX.model, REVISION, 'unloaded', 'noul', 'choice', 'score'):
            self.assertIn(value, out)

        code, out, err = await self.cli(*args, '--json')
        self.assertEqual(code, 0, err)
        result = json.loads(out)
        self.assertEqual(result['model'], MLX.model)
        self.assertEqual(result['backend_source'], 'service')
        self.assertEqual(result['local_model']['load_state'], 'unloaded')
        self.assertEqual(result['decision_types'], {
            'noul': 'supported', 'choice': 'supported', 'score': 'supported', 'box': 'unsupported'})

        code, out, err = await self.cli(*args, '--json', '--model', 'other/model')
        self.assertEqual(code, 0, err)
        result = json.loads(out)
        self.assertEqual(result['model'], 'other/model')
        self.assertEqual(result['local_model']['id'], MLX.model)
        self.assertEqual(set(result['decision_types'].values()), {'unsupported'})

        await self.service.close()
        out = io.StringIO()
        with patch.object(cli, 'BACKEND', 'mlx'), redirect_stdout(out):
            await cli.run(cli.parser().parse_args([*args, '--json']))
        result = json.loads(out.getvalue())
        self.assertEqual(result['backend_source'], 'package')
        self.assertEqual(result['local_model']['load_state'], 'unknown')

    async def test_info_uses_public_decisions_catalog(self):
        matched = {'id': 'cloudflare/clef-flash', 'canonical_slug': 'cloudflare/clef-flash',
                   'name': 'Clef Flash', 'context_length': 24576}
        alias = {'id': '~typesafe/jev-latest', 'alias_target': {'slug': 'typesafe/jev-1.14'}}
        jev = {'id': 'typesafe/jev-1.14', 'canonical_slug': 'typesafe/jev-1.14-20261014'}
        calls = []
        fail = False

        async def catalog(request):
            calls.append((request.query.get('endpoints'), request.headers.get('Authorization'),
                          await request.read()))
            if fail:
                return web.Response(status=503)
            return web.json_response({'data': [matched, alias, jev]})

        app = web.Application()
        app.router.add_get('/models', catalog)
        runner = web.AppRunner(app)
        await runner.setup()
        self.addAsyncCleanup(runner.cleanup)
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        port = runner.addresses[0][1]
        await self.service.close()
        self.service = Service(Judge(OpenRouter(api_key='test-key')), self.socket)
        await self.service.start()

        async def info(model):
            args = ['info', '--socket', self.socket, '--model', model, '--json']
            out = io.StringIO()
            with patch('decide.openrouter.MODELS_URL', f'http://127.0.0.1:{port}/models', create=True), redirect_stdout(out):
                await cli.run(cli.parser().parse_args(args))
            return json.loads(out.getvalue())

        result = await info('cloudflare/clef-flash')
        self.assertEqual(result['remote_model']['context_length'], 24576)
        self.assertEqual(result['decision_types'], {
            'noul': 'supported', 'choice': 'supported', 'score': 'supported', 'box': 'unknown'})
        result = await info('~typesafe/jev-latest')
        self.assertEqual(result['remote_model']['id'], 'typesafe/jev-1.14')
        self.assertEqual(result['decision_types']['box'], 'supported')
        result = await info('unlisted/model')
        self.assertEqual(result['catalog_status'], 'not_listed')
        self.assertEqual(set(result['decision_types'].values()), {'unknown'})
        fail = True
        result = await info('cloudflare/clef-flash')
        self.assertEqual(result['catalog_status'], 'unavailable')
        self.assertEqual(set(result['decision_types'].values()), {'unknown'})
        self.assertEqual(calls, [('/api/alpha/decisions', None, b'')] * 4)

    async def test_operation_metadata_from_ipc_and_cli(self):
        metadata = {'HTTP-Referer': 'https://example.com', 'X-OpenRouter-Title': 'test harness',
                    'X-OpenRouter-Categories': 'developer-tools', 'x-session-id': 'session-test'}
        received = []

        async def handler(request):
            received.append(({name: request.headers.get(name) for name in metadata},
                             request.headers.get('Authorization')))
            return web.json_response(RESPONSE)

        app = web.Application()
        app.router.add_post('/decisions', handler)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        try:
            await self.service.close()
            self.service = Service(Judge(OpenRouter(api_key='test-key',
                endpoint=f'http://127.0.0.1:{port}/decisions')), self.socket)
            await self.service.start()
            async with self.client.post('http://localhost/api/alpha/decisions', json=REQUEST,
                                        headers={**metadata, 'Authorization': 'must-not-forward'}) as response:
                self.assertEqual(response.status, 200)
                await response.read()
            args = [value for name, content in metadata.items() for value in ('--header', name + ': ' + content)]
            code, _, err = await self.cli('judge', '--socket', self.socket, *args, '-', input=json.dumps(REQUEST).encode())
            self.assertEqual(code, 0, err)
            self.assertEqual(received, [(metadata, 'Bearer test-key')] * 2)
        finally:
            await self.service.close()
            await runner.cleanup()

    async def test_abandoned_queued_request_never_executes(self):
        first = asyncio.create_task(self.post(dict(REQUEST, state='wait')))
        await self.backend.started.wait()
        _, writer = await asyncio.open_unix_connection(self.socket)
        document = json.dumps(dict(REQUEST, state='abandon')).encode()
        writer.write(b'POST /api/alpha/decisions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: '
                     + str(len(document)).encode() + b'\r\n\r\n' + document)
        await writer.drain()

        async def queued():
            while len(self.service.tasks) != 2:
                await asyncio.sleep(.01)

        await asyncio.wait_for(queued(), 5)
        writer.close()
        await writer.wait_closed()
        await asyncio.sleep(.05)
        self.backend.release.set()
        self.assertEqual((await first)[0], 200)
        self.assertEqual((await self.post(REQUEST))[0], 200)
        self.assertNotIn('abandon', [request['state'] for request in self.backend.requests])

    async def test_malformed_missing_and_unexpected_errors(self):
        async with self.client.post('http://localhost/api/alpha/decisions', data='{') as response:
            self.assertEqual((response.status, (await response.json())['error']['code']), (400, 400))
        status, body = await self.post({'state': 'bad'})
        self.assertEqual((status, body['error']['code']), (400, 400))
        status, body = await self.post(dict(REQUEST, state='unexpected'))
        self.assertEqual(status, 500)
        self.assertNotIn('secret', json.dumps(body))
        code, _, err = await self.cli('judge', '--socket', self.socket, '-', input=b'{')
        self.assertNotEqual(code, 0)
        self.assertIn('JSON', err)
        code, _, err = await self.cli('judge', '--socket', self.socket + '.missing', '-', input=json.dumps(REQUEST).encode())
        self.assertNotEqual(code, 0)
        self.assertIn('serve', err)

    async def test_live_stale_and_foreign_endpoints(self):
        with self.assertRaises(OSError):
            await Service(Judge(self.backend), self.socket).start()
        await self.service.close()
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(self.socket)
        stale.close()
        self.service = Service(Judge(self.backend), self.socket)
        await self.service.start()
        await self.service.close()
        self.assertFalse(Path(self.socket).exists())
        Path(self.socket).write_text('keep')
        with self.assertRaises(OSError):
            await Service(Judge(self.backend), self.socket).start()
        self.assertEqual(Path(self.socket).read_text(), 'keep')
        Path(self.socket).unlink()
        os.symlink('/missing', self.socket)
        with self.assertRaises(OSError):
            await Service(Judge(self.backend), self.socket).start()
        self.assertTrue(Path(self.socket).is_symlink())
        Path(self.socket).unlink()
        self.service = Service(Judge(self.backend), self.socket)
        await self.service.start()
        self.assertEqual(stat.S_IMODE(os.stat(self.socket).st_mode) & 0o077, 0)
        os.unlink(self.socket)
        Path(self.socket).write_text('replacement')
        await self.service.close()
        self.assertEqual(Path(self.socket).read_text(), 'replacement')

    async def test_packaged_service_lifecycle(self):
        executable = os.environ.get('DECIDE_TEST_CLI')
        command = [executable] if executable else [sys.executable, '-m', 'decide']
        path = str(Path(self.temp.name) / 'production.sock')
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(sys.path))
        process = await asyncio.create_subprocess_exec(*command, 'serve', '--socket', path,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
        try:
            line = await asyncio.wait_for(process.stderr.readline(), 10)
            self.assertIn(b'listening', line)
            async with ClientSession(connector=UnixConnector(path=path)) as client:
                async with client.post('http://localhost/api/alpha/decisions', data='{') as response:
                    self.assertEqual((response.status, (await response.json())['error']['code']), (400, 400))
            process.send_signal(signal.SIGTERM)
            await asyncio.wait_for(process.communicate(), 10)
            self.assertEqual(process.returncode, 0)
            self.assertFalse(Path(path).exists())
        finally:
            if process.returncode is None:
                process.terminate()
                await process.communicate()

    async def test_disconnect_does_not_overlap_and_failure_recovers(self):
        first = asyncio.create_task(self.post(dict(REQUEST, state='wait')))
        await self.backend.started.wait()
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        second = asyncio.create_task(self.post(REQUEST))
        await asyncio.sleep(.05)
        self.assertEqual(self.backend.max_active, 1)
        self.assertFalse(second.done())
        self.backend.release.set()
        self.assertEqual((await second)[0], 200)
        self.assertEqual((await self.post(dict(REQUEST, state='fail')))[0], 401)
        self.assertEqual((await self.post(REQUEST))[0], 200)
        self.assertEqual(self.backend.max_active, 1)

class RemoteLifecycle(unittest.IsolatedAsyncioTestCase):
    async def test_session_reuse_and_key_rotation(self):
        connections = []
        keys = []
        async def handler(request):
            connections.append(request.transport)
            keys.append(request.headers['Authorization'])
            return web.json_response(RESPONSE)
        app = web.Application()
        app.router.add_post('/decisions', handler)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        try:
            with tempfile.TemporaryDirectory() as directory:
                key = Path(directory) / 'key'
                key.write_text('first')
                backend = OpenRouter(key_file=key, endpoint=f'http://127.0.0.1:{port}/decisions')
                await backend.start()
                try:
                    await backend.judge(REQUEST)
                    key.write_text('second')
                    await backend.judge(REQUEST)
                finally:
                    await backend.close()
            self.assertEqual(keys, ['Bearer first', 'Bearer second'])
            self.assertIs(connections[0], connections[1])
        finally:
            await runner.cleanup()

if __name__ == '__main__':
    unittest.main()
