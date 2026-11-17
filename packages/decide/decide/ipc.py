import asyncio
import os
from pathlib import Path

import aiohttp

from .core import DecisionError, error

PATH = '/api/alpha/decisions'


def default_socket():
    runtime = os.environ.get('XDG_RUNTIME_DIR')
    base = Path(runtime) if runtime else Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache')
    return str(base / 'decide' / 'decide.sock')


async def request(socket, document, timeout):
    try:
        async with aiohttp.ClientSession(connector=aiohttp.UnixConnector(path=socket),
                                         timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.post('http://localhost' + PATH, json=document) as response:
                try:
                    body = await response.json(content_type=None)
                except (ValueError, UnicodeDecodeError):
                    raise error(502, 'Invalid response from the Decisions service') from None
                if not 200 <= response.status < 300:
                    raise DecisionError(response.status, body)
                return body
    except asyncio.TimeoutError:
        raise error(504, 'Request timed out; the service may still be processing it') from None
    except aiohttp.ClientError:
        raise error(503, 'Cannot reach the Decisions service; start decide serve and check the socket') from None
