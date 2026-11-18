from dataclasses import dataclass, replace
import math
import os
from pathlib import Path
import tomllib

try:
    from ._package import BACKEND, MODEL, KEY_FILE
except ImportError:
    BACKEND, MODEL, KEY_FILE = 'openrouter', 'typesafe/jev-1.14', None


@dataclass(frozen=True)
class Config:
    backend: str
    model: str
    socket: str
    timeout: float = 120
    openrouter_key_file: str | None = None
    preload: bool = False


def load_config(*, backend: str, model: str, socket: str,
                openrouter_key_file: str | None = None,
                path: str | Path | None = None) -> Config:
    settings = {}
    default = path is None
    if default:
        path = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'decide' / 'config.toml'
    try:
        with open(path, 'rb') as source:
            settings = tomllib.load(source)
    except FileNotFoundError:
        if not default:
            raise
    except tomllib.TOMLDecodeError:
        raise ValueError('Invalid TOML configuration') from None
    try:
        timeout = float(os.environ.get('DECIDE_TIMEOUT', settings.get('timeout', 120)))
    except (TypeError, ValueError):
        raise ValueError('Timeout must be a number of seconds') from None
    preload = settings.get('preload', False)
    if not isinstance(preload, bool):
        raise ValueError('Set preload to true or false')
    return Config(
        backend=backend,
        model=os.environ.get('DECIDE_MODEL', settings.get('model', model)),
        socket=os.environ.get('DECIDE_SOCKET', settings.get('socket', socket)),
        timeout=timeout,
        openrouter_key_file=settings.get('openrouter_key_file', openrouter_key_file),
        preload=preload,
    )


def command_config(config=None, **overrides):
    from .ipc import default_socket

    settings = load_config(backend=BACKEND, model=MODEL, socket=default_socket(),
                           openrouter_key_file=KEY_FILE, path=config)
    settings = replace(settings, **{name: value for name, value in overrides.items() if value is not None})
    if not math.isfinite(settings.timeout) or settings.timeout <= 0:
        raise ValueError('Timeout must be greater than zero')
    return settings
