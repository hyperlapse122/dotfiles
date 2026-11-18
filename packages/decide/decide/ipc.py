import asyncio
import os
from pathlib import Path

import aiohttp

from .core import DecisionError, error

PATH = '/api/alpha/decisions'
INFO_PATH = '/info'


def default_socket():
    runtime = os.environ.get('XDG_RUNTIME_DIR')
    base = Path(runtime) if runtime else Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache')
    return str(base / 'decide' / 'decide.sock')


async def service_status(socket, timeout):
    try:
        async with aiohttp.ClientSession(connector=aiohttp.UnixConnector(path=socket),
                                         timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.get('http://localhost' + INFO_PATH, allow_redirects=False) as response:
                if response.status == 200:
                    status = await response.json()
                    if isinstance(status, dict) and status.get('backend') == 'openrouter':
                        return {'backend': 'openrouter'}
                    if isinstance(status, dict) and status.get('backend') in ('mlx', 'cuda'):
                        model = status.get('local_model')
                        if (isinstance(model, dict) and isinstance(model.get('id'), str)
                                and isinstance(model.get('revision'), str)
                                and model.get('load_state') in ('loaded', 'unloaded')):
                            return {'backend': status['backend'], 'local_model': {
                                key: model[key] for key in ('id', 'revision', 'load_state')}}
    except (aiohttp.ClientError, TimeoutError, ValueError):
        return None


async def request(socket, document, timeout, *, headers=None):
    try:
        async with aiohttp.ClientSession(connector=aiohttp.UnixConnector(path=socket),
                                         timeout=aiohttp.ClientTimeout(total=timeout)) as session:
            async with session.post('http://localhost' + PATH, json=document, headers=headers) as response:
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
