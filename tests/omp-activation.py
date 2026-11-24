"""Execute the ompAuth activation block against a recording stub.

  omp-activation.py SCRIPT AUTH_SYNC EXPECTED

SCRIPT is the activation block, AUTH_SYNC the omp-auth-sync store path it
names, and EXPECTED a JSON file of the argument list the block must pass to
it. The block runs with that store path replaced by a stub that records its
argument list, so the check sees what is executed, not what the script text
happens to contain. The block must fail when the import fails, so a missing
key is never hidden, and must do nothing on a dry run.
"""
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

script_path, auth_sync, expected_path = sys.argv[1:]
script = Path(script_path).read_text()
expected = json.loads(Path(expected_path).read_text())
assert auth_sync in script, 'the block does not run the packaged omp-auth-sync'

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    log = root / 'calls.jsonl'
    stub = root / 'omp-auth-sync'
    stub.write_text('#!' + sys.executable + '\n'
                    'import json, os, sys\n'
                    'with open(os.environ["ACTIVATION_LOG"], "a") as stream:\n'
                    '    stream.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                    'sys.exit(int(os.environ.get("STUB_STATUS", "0")))\n')
    stub.chmod(0o755)
    (root / 'block.sh').write_text(script.replace(auth_sync, shlex.quote(str(stub))))

    def run(**extra):
        log.unlink(missing_ok=True)
        env = {key: value for key, value in os.environ.items() if key != 'DRY_RUN'}
        env.update(ACTIVATION_LOG=str(log), **extra)
        result = subprocess.run(['bash', '-euo', 'pipefail', str(root / 'block.sh')], env=env, cwd=root,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    result, calls = run()
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1 and sorted(zip(calls[0][0::2], calls[0][1::2])) == sorted(
        zip(expected[0::2], expected[1::2])), calls

    result, calls = run(DRY_RUN='1')
    assert result.returncode == 0 and not calls, 'a dry run executed the import'

    result, calls = run(STUB_STATUS='7')
    assert calls, 'the failing run never reached the import'
    assert result.returncode != 0, 'a failed credential import was swallowed'
