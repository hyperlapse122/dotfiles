from dataclasses import dataclass
import os
from pathlib import Path
import tomllib


@dataclass(frozen=True)
class Config:
    backend: str
    model: str
    socket: str
    timeout: float = 120
    openrouter_key_file: str | None = None


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
    return Config(
        backend=backend,
        model=os.environ.get('DECIDE_MODEL', settings.get('model', model)),
        socket=os.environ.get('DECIDE_SOCKET', settings.get('socket', socket)),
        timeout=timeout,
        openrouter_key_file=settings.get('openrouter_key_file', openrouter_key_file),
    )
