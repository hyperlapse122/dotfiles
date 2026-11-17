import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp import web

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages' / 'decide'))

from decide.core import DecisionError, Judge
from decide.config import load_config
from decide.openrouter import OpenRouter
from decide.schema import validate_request, validate_response

REQUEST = {
    'model': 'example/decision',
    'state': ['asset-one', {'type': 'image_url', 'image_url': {'url': 'https://example.com/x.png'}},
              {'type': 'input_audio', 'input_audio': {'data': 'YWJj', 'format': 'wav'}},
              {'type': 'video_url', 'video_url': {'url': 'https://example.com/x.mp4'}},
              {'type': 'file', 'file': {'file_data': 'data:application/pdf;base64,YWJj'}}],
    'questions': {
        'probability': {'type': 'noul', 'instructions': {'ask': ['is it ready?']},
                        'criteria': {'true': ['ready'], 'false': None}},
        'category': {'type': 'choice', 'criteria': {'a': {'rule': 1}, 'b': None}},
        'rating': {'type': 'score', 'criteria': ['low', {'level': 'high'}]},
        'location': {'type': 'box', 'instructions': ['find object']},
    },
    'assets': {'asset-one': {'format': 'png', 'data_base64': 'YWJj'}},
    'provider': {'allow_fallbacks': False, 'order': ['example']},
    'session_id': 'session', 'user': 'user', 'trace': {'trace_id': 'trace', 'custom': 'kept'},
    'extra_field': {'preserved': True},
}
RESPONSE = {
    'model': 'example/decision-v1',
    'answers': {'probability': {'type': 'noul', 'noul': 0.73},
                'category': {'type': 'choice', 'choice': 'a'},
                'rating': {'type': 'score', 'score': 0.5, 'legend': {'0': {'label': 'low'}}},
                'location': {'type': 'refusal', 'reason': 'not available'},
                'other': {'type': 'box', 'box': {'top': 0.1, 'bottom': 0.8, 'left': 0.2, 'right': 0.9}}},
    'usage': {'input_tokens': 12, 'output_tokens': 4, 'input_tokens_details': {'cached_tokens': 2}},
    'annotations': [{'type': 'url_citation', 'url_citation': {'url': 'https://example.com'}}],
    'provider': 'example', 'id': 'decision-id', 'extra': {'kept': True},
}


class Contract(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.received = []
        self.status = 200
        self.payload = RESPONSE

        async def handler(request):
            self.received.append((await request.json(), request.headers.get('Authorization')))
            return web.json_response(self.payload, status=self.status)

        app = web.Application()
        app.router.add_post('/api/alpha/decisions', handler)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, '127.0.0.1', 0)
        await site.start()
        self.url = 'http://127.0.0.1:' + str(site._server.sockets[0].getsockname()[1]) + '/api/alpha/decisions'

    async def asyncTearDown(self):
        await self.runner.cleanup()

    async def test_full_request_and_response_cross_http_unchanged(self):
        validate_request(REQUEST)
        validate_response(RESPONSE)
        judge = Judge(OpenRouter(api_key='test-key', endpoint=self.url))
        self.assertEqual(await judge.judge(REQUEST), RESPONSE)
        self.assertEqual(self.received, [(REQUEST, 'Bearer test-key')])

    async def test_official_error_envelope_survives(self):
        self.status = 400
        self.payload = {'error': {'code': 400, 'message': 'unsupported input', 'metadata': {'reason': 'box'}},
                        'user_id': 'example'}
        judge = Judge(OpenRouter(api_key='test-key', endpoint=self.url))
        with self.assertRaises(DecisionError) as caught:
            await judge.judge(REQUEST)
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(caught.exception.body, self.payload)

    async def test_invalid_variants_fail_and_additional_fields_remain_valid(self):
        invalid = copy.deepcopy(REQUEST)
        invalid['questions']['rating']['criteria'] = []
        with self.assertRaises(DecisionError) as caught:
            validate_request(invalid)
        self.assertEqual(caught.exception.status, 400)
        invalid = copy.deepcopy(RESPONSE)
        invalid['answers']['probability']['noul'] = True
        with self.assertRaises(DecisionError):
            validate_response(invalid)
        invalid = copy.deepcopy(REQUEST)
        invalid['assets']['asset-one']['part'] = 'disallowed'
        with self.assertRaises(DecisionError):
            validate_request(invalid)
        invalid = {key: value for key, value in REQUEST.items() if key != 'model'}
        with self.assertRaises(DecisionError) as caught:
            await Judge(OpenRouter(api_key='test-key', endpoint=self.url)).judge(invalid)
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(self.received, [])

    async def test_config_keeps_packaged_backend_and_runtime_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'config.toml'
            path.write_text('model = "file/model"\nsocket = "/file.sock"\ntimeout = 9\nopenrouter_key_file = "/configured-key"\n')
            with patch.dict(os.environ, {'DECIDE_MODEL': 'env/model'}, clear=True):
                config = load_config(backend='native', model='default/model', socket='/default.sock',
                                     openrouter_key_file='/key', path=path)
        self.assertEqual((config.backend, config.model, config.socket, config.timeout,
                          config.openrouter_key_file),
                         ('native', 'env/model', '/file.sock', 9.0, '/configured-key'))


if __name__ == '__main__':
    unittest.main()
