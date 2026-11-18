import asyncio
import json
from pathlib import Path

import aiohttp

from .core import DecisionError, error, operation_headers
from .ipc import PATH

MODELS_URL = 'https://openrouter.ai/api/v1/models'
ROUTED_DECISION_TYPES = ('noul', 'choice', 'score')
BOX_MODELS = {'typesafe/jev-1.14'}


async def model_metadata(model, timeout):
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.get(MODELS_URL, params={'endpoints': PATH}, allow_redirects=False) as response:
                if response.status != 200:
                    return 'unavailable', None
                document = await response.json()
    except (aiohttp.ClientError, TimeoutError, ValueError):
        return 'unavailable', None
    if not isinstance(document, dict) or not isinstance(document.get('data'), list):
        return 'unavailable', None

    entries = [entry for entry in document['data'] if isinstance(entry, dict)]
    selected = next((entry for entry in entries if model == entry.get('id')), None)
    if selected is None:
        selected = next((entry for entry in entries if model == entry.get('canonical_slug')), None)
    if selected is None:
        return 'not_listed', None

    alias = selected.get('alias_target')
    slug = alias.get('slug') if isinstance(alias, dict) else None
    if isinstance(slug, str):
        selected = next((entry for entry in entries if entry.get('id') == slug), selected)
    return 'matched', {key: selected[key] for key, value_type in
                       (('id', str), ('name', str), ('context_length', int))
                       if isinstance(selected.get(key), value_type)}


class OpenRouter:
    cancel_on_disconnect = True

    def __init__(self, *, api_key=None, key_file=None,
                 endpoint='https://openrouter.ai/api/alpha/decisions', timeout=120):
        self.api_key = api_key
        self.key_file = Path(key_file) if key_file is not None else None
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = None

    def status(self):
        return {'backend': 'openrouter'}

    async def start(self):
        self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout),
                                             trust_env=True)

    async def close(self):
        if self.session is not None:
            await self.session.close()
            self.session = None

    async def judge(self, request, *, headers=None):
        try:
            key = self.api_key if self.api_key is not None else self.key_file.read_text().strip()
        except (OSError, AttributeError):
            raise error(401, 'OpenRouter credential is unavailable; check the configured key file') from None
        if not key:
            raise error(401, 'OpenRouter credential is unavailable; check the configured key file')
        async def send(session):
            async with session.post(self.endpoint, json=request,
                                    headers={**operation_headers(headers), 'Authorization': f'Bearer {key}'}) as response:
                try:
                    body = json.loads(await response.read())
                except (ValueError, UnicodeDecodeError):
                    raise error(502, 'Invalid response from OpenRouter') from None
                if not 200 <= response.status < 300:
                    raise DecisionError(response.status, body)
                return body
        try:
            if self.session is not None:
                return await send(self.session)
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout),
                                             trust_env=True) as session:
                return await send(session)
        except asyncio.TimeoutError:
            raise error(524, 'OpenRouter request timed out') from None
        except aiohttp.ClientError:
            raise error(502, 'OpenRouter request failed') from None
