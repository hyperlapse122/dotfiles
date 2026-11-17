import asyncio
import base64
import copy
import contextlib
from types import SimpleNamespace
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp import web
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packages' / 'decide'))
from decide.core import DecisionError, Judge
from decide.mlx import MLX
from decide.cuda import CUDA

MODEL = 'mlx-community/clef-flash-8bit'
REQUEST = {'model': MODEL, 'state': '안녕하세요', 'questions': {
    'yes': {'type': 'noul', 'instructions': {'ask': ['인사인가요?']}, 'criteria': {'true': ['예'], 'false': None}},
    'choice': {'type': 'choice', 'criteria': {'a': {'label': '하나'}, 'b': ['둘']}},
    'score': {'type': 'score', 'criteria': ['낮음', {'label': '높음'}]},
}}

class Head:
    def __init__(self):
        self.calls = []
    def systemone(self, record, **kwargs):
        self.calls.append((record, kwargs))
        return {'model': record['model'], 'answers': {
            'yes': {'type': 'noul', 'noul': .8}, 'choice': {'type': 'choice', 'choice': 'a'},
            'score': {'type': 'score', 'score': .5, 'legend': {'0': '낮음', '1': {'label': '높음'}}}},
            'usage': {'input_tokens': 17, 'output_tokens': 0}}

class Local(unittest.IsolatedAsyncioTestCase):
    async def test_remote_image_deadline_and_recovery(self):
        from PIL import Image
        image = io.BytesIO()
        Image.new('RGB', (2, 2), 'red').save(image, 'PNG')
        disconnected = asyncio.Event()
        completed = []

        async def slow(request):
            response = web.StreamResponse()
            await response.prepare(request)
            try:
                for _ in range(100):
                    await response.write(b'x')
                    await asyncio.sleep(.01)
                completed.append(True)
            except ConnectionResetError:
                pass
            finally:
                disconnected.set()
            return response

        app = web.Application()
        app.router.add_get('/slow', slow)
        app.router.add_get('/image', lambda request: web.Response(body=image.getvalue()))
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, '127.0.0.1', 0)
        await site.start()
        url = 'http://127.0.0.1:' + str(site._server.sockets[0].getsockname()[1])
        backend = MLX('/missing')
        backend._head = Head()
        request = copy.deepcopy(REQUEST)
        try:
            request['state'] = [{'type': 'image_url', 'image_url': {'url': url + '/slow'}}]
            with patch('decide.local.IMAGE_TIMEOUT', .15, create=True):
                with self.assertRaises(DecisionError) as caught:
                    await asyncio.wait_for(Judge(backend).judge(request), 5)
            self.assertEqual(caught.exception.status, 400)
            await asyncio.wait_for(disconnected.wait(), 5)
            self.assertEqual(completed, [], 'The deadline must close a still-streaming response')
            request['state'][0]['image_url']['url'] = url + '/image'
            await Judge(backend).judge(request)
            self.assertEqual(len(backend._head.calls[0][0]['images']), 1)
        finally:
            await runner.cleanup()

    async def test_structured_guidance_and_actual_usage(self):
        head = Head()
        backend = MLX('/reviewed/clef_mlx.py')
        backend._head = head
        result = await Judge(backend).judge(REQUEST)
        self.assertEqual(result['usage'], {'input_tokens': 17, 'output_tokens': 0})
        record, kwargs = head.calls[0]
        self.assertEqual(record['questions'], REQUEST['questions'])
        self.assertEqual(kwargs['truncate'], False)
        self.assertEqual(result['answers']['yes']['noul'], .8)

    async def test_image_association_and_order(self):
        from PIL import Image
        buf = io.BytesIO()
        Image.new('RGB', (2, 2), 'red').save(buf, 'PNG')
        data = base64.b64encode(buf.getvalue()).decode()
        request = copy.deepcopy(REQUEST)
        request['assets'] = {'first': {'format': 'png', 'data_base64': data}}
        request['state'] = ['앞', 'first', '뒤', {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + data}}]
        head = Head()
        backend = MLX('/reviewed/clef_mlx.py')
        backend._head = head
        await Judge(backend).judge(request)
        record = head.calls[0][0]
        self.assertEqual(len(record['images']), 2)
        self.assertLess(record['state'].index('앞'), record['state'].index('Image 1'))
        self.assertLess(record['state'].index('Image 1'), record['state'].index('뒤'))
        self.assertLess(record['state'].index('뒤'), record['state'].index('Image 2'))
        animated = io.BytesIO()
        Image.new('RGB', (2, 2), 'red').save(animated, 'GIF', save_all=True,
                                           append_images=[Image.new('RGB', (2, 2), 'blue')])
        request['assets'] = {}
        request['state'] = [{'type': 'image_url', 'image_url': {
            'url': 'data:image/gif;base64,' + base64.b64encode(animated.getvalue()).decode()}}]
        with self.assertRaises(DecisionError) as caught:
            await Judge(backend).judge(request)
        self.assertEqual(caught.exception.status, 400)

    async def test_unsupported_requests_never_load(self):
        cases = []
        for patch_doc in ({'provider': {'order': ['x']}}, {'model': 'other'},
                          {'state': [{'type': 'input_audio', 'input_audio': {'data': 'YQ==', 'format': 'wav'}}]},
                          {'state': [{'type': 'video_url', 'video_url': {'url': 'https://example.com/a.mp4'}}]},
                          {'state': [{'type': 'file', 'file': {'file_data': 'data:application/pdf;base64,YQ=='}}]},
                          {'questions': {'x': {'type': 'box', 'instructions': 'find'}}}):
            case = copy.deepcopy(REQUEST); case.update(patch_doc); cases.append(case)
        for backend in (MLX('/missing'), CUDA('/missing')):
            for original in cases:
                case = copy.deepcopy(original)
                if case['model'] == MODEL:
                    case['model'] = backend.model
                with self.subTest(backend=type(backend).__name__, case=case):
                    with patch.object(backend, '_load', side_effect=AssertionError('must not load')):
                        with self.assertRaises(DecisionError) as caught:
                            await Judge(backend).judge(case)
                    self.assertEqual(caught.exception.status, 400)

    async def test_cuda_head_receives_images_and_rejects_overflow(self):
        class Adapter:
            def __init__(self):
                self.length = 12
                self.seen = None
            def encode(self, record):
                self.seen = record
                return SimpleNamespace(length=self.length, questions=[SimpleNamespace(question_id='yes')])
            def collate(self, encs, pad):
                return encs
            def to_device(self, batch, device):
                self.device = device
                return batch
            def forward(self, batch):
                return [['native-logits']]
            def answer(self, question, original, logits):
                self.logits = logits
                return {'type': 'noul', 'noul': .7}
        from PIL import Image
        buffer = io.BytesIO()
        Image.new('RGB', (2, 2), 'red').save(buffer, 'PNG')
        request = {'model': CUDA.model, 'state': [{'type': 'image_url', 'image_url': {
            'url': 'data:image/png;base64,' + base64.b64encode(buffer.getvalue()).decode()}}],
            'questions': {'yes': {'type': 'noul', 'instructions': '빨간색인가요?'}}}
        adapter = Adapter()
        backend = CUDA('/missing')
        backend._head = (adapter, 'cuda:0')
        with patch.dict(sys.modules, {'torch': SimpleNamespace(inference_mode=contextlib.nullcontext)}):
            response = await Judge(backend).judge(request)
            self.assertEqual(response['usage']['input_tokens'], 12)
            self.assertEqual(adapter.device, 'cuda:0')
            self.assertEqual(adapter.logits, 'native-logits')
            self.assertEqual(len(adapter.seen['images']), 1)
            adapter.length = 16385
            with self.assertRaises(DecisionError) as caught:
                await Judge(backend).judge(request)
            self.assertEqual(caught.exception.status, 413)

    async def test_empty_structured_instructions_survive_loader_fallback(self):
        request = copy.deepcopy(REQUEST)
        request['questions']['yes']['instructions'] = []
        head = Head()
        backend = MLX('/missing')
        backend._head = head
        await Judge(backend).judge(request)
        self.assertEqual(head.calls[0][0]['questions']['yes']['instructions'], '[]')

    async def test_overflow_and_load_failure_remain_errors(self):
        backend = MLX('/missing')
        with patch.object(backend, '_load', side_effect=RuntimeError('private-request-content')):
            with self.assertRaises(DecisionError) as caught:
                await backend.judge(REQUEST)
            self.assertEqual(caught.exception.status, 502)
            self.assertNotIn('private-request-content', str(caught.exception.body))
        class ContextTooLong(ValueError):
            pass
        class Overflow(Head):
            def systemone(self, record, **kwargs):
                raise ContextTooLong('context too long')
        backend._head = Overflow()
        with self.assertRaises(DecisionError) as caught:
            await backend.judge(REQUEST)
        self.assertEqual(caught.exception.status, 413)

if __name__ == '__main__':
    unittest.main()
