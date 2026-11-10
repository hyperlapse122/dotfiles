#!/usr/bin/env python3
"""Native Antigravity remains user-owned when T3 settings merge."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    merger, declared = sys.argv[1:3]
    native = {'driver': 'antigravity', 'enabled': False,
              'config': {'binaryPath': '/user/runtime', 'other': True}}
    with tempfile.TemporaryDirectory() as scratch:
        target = Path(scratch) / 'settings.json'
        target.write_text(json.dumps({'providerInstances': {'antigravity': native}}))
        for _ in range(2):
            subprocess.run([merger, '--settings', str(target), '--declared', declared,
                            '--ledger', str(Path(scratch) / 'ledger.json')], check=True)
            assert json.loads(target.read_text())['providerInstances']['antigravity'] == native


if __name__ == '__main__':
    main()
