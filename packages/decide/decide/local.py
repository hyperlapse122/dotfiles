"""Conversion shared by the reviewed Clef decision-head loaders."""
import asyncio
import base64
import importlib.util
import io
import json
import sys
import urllib.request

from .core import DecisionError, error

MAX_TOKENS = 16384


def reviewed_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def snapshot(model, revision):
    from huggingface_hub import snapshot_download
    return snapshot_download(model, revision=revision, token=False, ignore_patterns=['*.py', '*.pyc'])


def _image(data):
    from PIL import Image
    try:
        image = Image.open(io.BytesIO(data))
        if getattr(image, 'is_animated', False):
            raise error(400, 'Animated images are not supported by this backend')
        image.load()
        return image.convert('RGB')
    except (ValueError, OSError) as exc:
        raise error(400, 'Invalid image data') from exc


def _url_image(url):
    try:
        if url.startswith('data:image/') and ';base64,' in url:
            return _image(base64.b64decode(url.split(',', 1)[1], validate=True))
        if url.startswith(('http://', 'https://')):
            with urllib.request.urlopen(url, timeout=30) as response:
                return _image(response.read())
    except (ValueError, OSError) as exc:
        raise error(400, 'Could not read image') from exc
    raise error(400, 'Unsupported image URL')


def convert(request, model):
    if request['model'] != model:
        raise error(400, 'Model is not supported by this backend')
    if 'provider' in request:
        raise error(400, 'Provider preferences are not supported by this backend')
    if set(request) - {'model', 'state', 'questions', 'assets', 'user', 'session_id', 'trace'}:
        raise error(400, 'Unsupported request fields')
    questions = request['questions']
    if not questions:
        raise error(400, 'At least one question is required')
    native_questions = {}
    for key, q in questions.items():
        if not key.strip() or q['type'] not in ('noul', 'choice', 'score'):
            raise error(400, 'Unsupported question')
        if set(q) - {'type', 'instructions', 'criteria'}:
            raise error(400, 'Unsupported question fields')
        if q['type'] != 'noul' and not q.get('criteria'):
            raise error(400, 'Question criteria must not be empty')
        if q['type'] == 'noul' and set(q.get('criteria') or {}) - {'true', 'false'}:
            raise error(400, 'Unsupported noul criteria')
        native_q = dict(q)
        # The MLX loader otherwise replaces empty structured guidance with the ID.
        if 'instructions' in q and q['instructions'] in ('', [], {}):
            native_q['instructions'] = json.dumps(q['instructions'], ensure_ascii=False)
        native_questions[key] = native_q
    assets = request.get('assets', {})
    used = set()
    images = []

    def check_nested(value):
        if isinstance(value, str):
            if any(key in value for key in assets if key):
                raise error(400, 'Asset references are supported only as whole state items')
        elif isinstance(value, list):
            for item in value:
                check_nested(item)
        elif isinstance(value, dict):
            if value.get('type') in ('image_url', 'input_audio', 'video_url', 'file'):
                raise error(400, 'Media is supported only as top-level image state items')
            for item in value.values():
                check_nested(item)

    check_nested(questions)
    state = request['state']
    if isinstance(state, list):
        parts = []
        for part in state:
            if isinstance(part, str) and part in assets:
                asset = assets[part]
                if asset['format'] not in ('png', 'jpg', 'jpeg'):
                    raise error(400, 'Unsupported image asset format')
                try:
                    image = _image(base64.b64decode(asset['data_base64'], validate=True))
                except ValueError as exc:
                    raise error(400, 'Invalid image asset') from exc
                used.add(part)
            elif isinstance(part, dict) and part.get('type') == 'image_url':
                if set(part) != {'type', 'image_url'} or not isinstance(part['image_url'], dict) or set(part['image_url']) != {'url'}:
                    raise error(400, 'Unsupported image options')
                image = _url_image(part['image_url']['url'])
            else:
                check_nested(part)
                parts.append(part)
                continue
            images.append(image)
            parts.append(f'[Image {len(images)}: the corresponding image in the image prefix]')
        if images:
            state = 'Images in the prefix are numbered in their original state order. State: ' + json.dumps(parts, ensure_ascii=False, separators=(',', ':'))
    else:
        check_nested(state)
    if set(assets) != used:
        raise error(400, 'Unused or unsupported image asset reference')
    return {'model': model, 'state': state, 'questions': native_questions, **({'images': images} if images else {})}


class Local:
    model = ''

    def __init__(self, loader_path):
        self.loader_path = loader_path
        self._head = None

    async def judge(self, request):
        try:
            record = await asyncio.to_thread(convert, request, self.model)
            return await asyncio.to_thread(self._judge, record)
        except DecisionError:
            raise
        except Exception as exc:
            if exc.__class__.__name__ in ('ContextTooLong', 'InputTooLarge'):
                raise error(413, 'Maximum context length exceeded') from exc
            raise error(502, 'Local inference failed; check the model cache and native runtime') from exc

    def _judge(self, record):
        if self._head is None:
            self._head = self._load()
        return self._infer(record)
