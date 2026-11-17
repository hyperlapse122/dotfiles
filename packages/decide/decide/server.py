"""Private HTTP-over-Unix service for a shared Judge."""
import asyncio
import errno
import fcntl
import os
from pathlib import Path
import socket
import stat

from aiohttp import web

from .core import DecisionError, error
from .ipc import PATH


def _private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError('Socket directory must be private and owned by the current user')


def _same(path, info):
    try:
        current = path.lstat()
        return (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino)
    except FileNotFoundError:
        return False


@web.middleware
async def _http_errors(request, handler):
    try:
        return await handler(request)
    except web.HTTPException as exc:
        return web.json_response({'error': {'code': exc.status, 'message': exc.reason}}, status=exc.status)


def _finished(task):
    if not task.cancelled():
        task.exception()


class Service:
    def __init__(self, judge, path):
        self.judge = judge
        self.path = Path(path)
        self.lock_fd = None
        self.endpoint = None
        self.runner = None
        self.site = None
        self.tasks = set()
        self.serial = asyncio.Lock()

    def _claim(self):
        _private_directory(self.path.parent)
        lock = str(self.path) + '.lock'
        self.lock_fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.lock_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OSError('Socket lock must be private and owned by the current user')
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OSError('A Decisions service already owns this socket') from None
        try:
            info = self.path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise OSError('Refusing to replace a foreign or non-socket endpoint')
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.settimeout(1)
            probe.connect(str(self.path))
        except OSError as exc:
            if exc.errno != errno.ECONNREFUSED:
                raise OSError('Cannot verify that the socket is stale') from None
        else:
            raise OSError('A service is already listening on this socket')
        finally:
            probe.close()
        if not _same(self.path, info):
            raise OSError('Socket changed while checking ownership')
        self.path.unlink()

    async def start(self):
        try:
            self._claim()
            app = web.Application(middlewares=[_http_errors], client_max_size=0)
            app.router.add_post(PATH, self._handle)
            self.runner = web.AppRunner(app, access_log=None)
            await self.runner.setup()
            self.site = web.UnixSite(self.runner, str(self.path))
            old_umask = os.umask(0o177)
            try:
                await self.site.start()
            finally:
                os.umask(old_umask)
            self.endpoint = self.path.lstat()
            backend = self.judge.backend
            if hasattr(backend, 'start'):
                await backend.start()
        except BaseException:
            await self.close()
            raise

    async def _execute(self, document):
        async with self.serial:
            return await self.judge.judge(document)

    async def _handle(self, request):
        try:
            try:
                document = await request.json()
            except (ValueError, UnicodeDecodeError):
                raise error(400, 'Invalid JSON request') from None
            task = asyncio.create_task(self._execute(document))
            self.tasks.add(task)
            task.add_done_callback(self.tasks.discard)
            task.add_done_callback(_finished)
            result = await asyncio.shield(task)
            return web.json_response(result)
        except web.HTTPException:
            raise
        except DecisionError as exc:
            return web.json_response(exc.body, status=exc.status)
        except Exception:
            return web.json_response({'error': {'code': 500, 'message': 'Decisions service failed'}}, status=500)

    async def close(self):
        if self.site is not None:
            await self.site.stop()
            self.site = None
        if self.runner is not None:
            await self.runner.cleanup()
            self.runner = None
        if self.tasks:
            await asyncio.gather(*self.tasks, return_exceptions=True)
        if self.endpoint is not None:
            backend = self.judge.backend
            if hasattr(backend, 'close'):
                await backend.close()
        if self.endpoint is not None and _same(self.path, self.endpoint):
            self.path.unlink()
        self.endpoint = None
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None
