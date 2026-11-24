"""Reject retired agent binaries and deliveries in materialized profiles."""
import json
from pathlib import Path
import sys

entries = json.loads(Path(sys.argv[1]).read_text())
assert entries, 'no host configurations checked'
for entry in entries:
    for name in ('agy', 'agy_acp_server.par', 'localharness_external'):
        binary = Path(entry['profile']) / 'bin' / name
        assert not binary.exists() and not binary.is_symlink(), (entry['name'], str(binary))
    files = Path(entry['files'])
    assert files.is_dir(), entry['name']
    gemini = files / '.gemini'
    assert not gemini.exists() and not gemini.is_symlink(), (entry['name'], str(gemini))
