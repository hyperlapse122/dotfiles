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
    if path is not None:
        with open(path, 'rb') as source:
            settings = tomllib.load(source)
    return Config(
        backend=backend,
        model=os.environ.get('DECIDE_MODEL', settings.get('model', model)),
        socket=os.environ.get('DECIDE_SOCKET', settings.get('socket', socket)),
        timeout=float(os.environ.get('DECIDE_TIMEOUT', settings.get('timeout', 120))),
        openrouter_key_file=openrouter_key_file,
    )
