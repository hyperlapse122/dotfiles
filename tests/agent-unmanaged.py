import json
from pathlib import Path
import sys

entries = json.loads(Path(sys.argv[1]).read_text())
assert entries, 'no host configurations checked'
for entry in entries:
    for name in ('agy', 'agy_acp_server.par', 'localharness_external',
                 'pi', 'pi-state'):
        binary = Path(entry['profile']) / 'bin' / name
        assert not binary.exists() and not binary.is_symlink(), (entry['name'], str(binary))
    files = Path(entry['files'])
    assert files.is_dir(), entry['name']
    for home in ('.gemini', '.pi'):
        path = files / home
        assert not path.exists() and not path.is_symlink(), (entry['name'], str(path))
