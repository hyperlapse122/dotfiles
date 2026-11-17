import asyncio
import json
from pathlib import Path

import aiohttp

from .core import DecisionError, error


class OpenRouter:
    def __init__(self, *, api_key=None, key_file=None,
                 endpoint='https://openrouter.ai/api/alpha/decisions', timeout=120):
        self.api_key = api_key
        self.key_file = Path(key_file) if key_file is not None else None
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = None

    async def start(self):
        self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout),
                                             trust_env=True)

    async def close(self):
        if self.session is not None:
            await self.session.close()
            self.session = None

    async def judge(self, request):
        try:
            key = self.api_key if self.api_key is not None else self.key_file.read_text().strip()
        except (OSError, AttributeError):
            raise error(401, 'OpenRouter credential is unavailable; check the configured key file') from None
        if not key:
            raise error(401, 'OpenRouter credential is unavailable; check the configured key file')
        async def send(session):
            async with session.post(self.endpoint, json=request,
                                    headers={'Authorization': f'Bearer {key}'}) as response:
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
