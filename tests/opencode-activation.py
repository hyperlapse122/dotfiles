"""Execute the opencodePlugin and opencodeAuth activation blocks against recording stubs.

  opencode-activation.py MODE SCRIPT HOME OPENCODE AUTH_SYNC EXPECTED

MODE is `plugin` or `auth`. SCRIPT is the activation block, HOME the home
directory it was rendered for, OPENCODE and AUTH_SYNC the store paths it names,
and EXPECTED a JSON file of the argument list the block must pass to the tool
it runs. The block runs in a scratch HOME with both store paths replaced by a
stub that records its argument list, so the check sees what is executed, not
what the script text happens to contain.

The plugin block must warn and continue when its install fails: a network
failure must not abort every later activation step. The auth block must fail
when its tool fails, so a missing key is never hidden. Both do nothing on a
dry run.
"""
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

mode, script_path, original_home, opencode, auth_sync, expected_path = sys.argv[1:]
script = Path(script_path).read_text()
expected = json.loads(Path(expected_path).read_text())
assert original_home.startswith('/') and original_home != '/', 'unsafe home replacement'
assert opencode in script, 'the block does not run the managed opencode'
if mode == 'auth':
    assert auth_sync in script, 'the block does not run the packaged opencode-auth-sync'

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    home = root / 'home'
    home.mkdir()
    log = root / 'calls.jsonl'
    recorder = ('#!' + sys.executable + '\n'
                'import json, os, sys\n'
                'with open(os.environ["ACTIVATION_LOG"], "a") as stream:\n'
                '    stream.write(json.dumps({"tool": os.path.basename(sys.argv[0]), "args": sys.argv[1:]}) + "\\n")\n'
                'sys.exit(int(os.environ.get("STUB_STATUS", "0")))\n')
    stubs = {}
    for name in ('opencode', 'opencode-auth-sync'):
        stubs[name] = root / name
        stubs[name].write_text(recorder)
        stubs[name].chmod(0o755)
    block = script.replace(original_home, str(home))
    block = block.replace(opencode, shlex.quote(str(stubs['opencode'])))
    block = block.replace(auth_sync, shlex.quote(str(stubs['opencode-auth-sync'])))
    (root / 'block.sh').write_text(block)

    def run(**extra):
        log.unlink(missing_ok=True)
        env = {key: value for key, value in os.environ.items() if key != 'DRY_RUN'}
        env.update(HOME=str(home), ACTIVATION_LOG=str(log), **extra)
        result = subprocess.run(['bash', '-euo', 'pipefail', str(root / 'block.sh')], env=env, cwd=home,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    tool = 'opencode' if mode == 'plugin' else 'opencode-auth-sync'
    want = [a.replace(original_home, str(home)).replace(opencode, str(stubs['opencode'])) for a in expected]
    result, calls = run()
    assert result.returncode == 0, result.stderr
    assert calls == [{'tool': tool, 'args': want}], calls

    result, calls = run(DRY_RUN='1')
    assert result.returncode == 0 and not calls, 'a dry run executed the tool'

    result, calls = run(STUB_STATUS='7')
    assert calls, 'the failing run never reached the tool'
    if mode == 'plugin':
        assert result.returncode == 0, 'a failed plugin install aborted activation'
        assert 'opencodePlugin' in result.stderr, 'a failed plugin install was silent'
    else:
        assert result.returncode != 0, 'a failed credential sync was swallowed'
