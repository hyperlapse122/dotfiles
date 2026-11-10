"""Check interface:

    python3 tests/retired-brew-effects.py <system-generation>/activate

Runs the retired-cask and retired-tap part of a materialized nix-darwin
activate script with retiredBrew replaced by a recording stub, under `set -e`
like the real script. A wrong comparison, a lost guard, or a step out of order
changes the calls the stub records or fails the apply, where a check on the
script's spelling would stay green.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

BODY = Path(sys.argv[1]).read_text()
END = 'echo "retired taps: removed the stablyai/orca tap" >&2\nfi\n'
start = BODY.index('retiredBrew() {\n')
block = BODY[start:BODY.index(END, start) + len(END)]
# Drop the real definition, which calls brew through sudo, so the stub below
# is the one the steps call.
block = re.sub(r'retiredBrew\(\) \{\n.*?\n\}\n', '', block, count=1, flags=re.S)

STUB = r'''
retiredBrew() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$1" in
    list)
      case "$*" in
        *orca*)
          case "$ORCA" in
            installed) return 0 ;;
            broken) echo boom >&2; return 1 ;;
            *) echo "Error: Cask 'orca' is not installed." >&2; return 1 ;;
          esac ;;
        *) return 1 ;;
      esac ;;
    uninstall) [ "$FAIL" != uninstall ] ;;
    tap)
      [ "$FAIL" != tap ] || { echo nope; return 1; }
      if [ "$TAPPED" = 1 ]; then printf 'homebrew/core\nstablyai/orca\n'; else printf 'homebrew/core\nx/stablyai/orca\n'; fi ;;
    untap) [ "$FAIL" != untap ] ;;
  esac
}
'''


def run(**overrides):
    with tempfile.TemporaryDirectory() as scratch:
        calls = Path(scratch) / 'calls'
        calls.touch()
        env = dict(os.environ, CALLS=str(calls), ORCA='absent', TAPPED='0', FAIL='')
        env.update(overrides)
        result = subprocess.run(['bash', '-e', '-c', STUB + block], env=env, capture_output=True, text=True)
        assert result.returncode == 0, ('retirement failed the apply', overrides, result.stderr)
        return calls.read_text().splitlines(), result.stderr


calls, log = run(ORCA='installed', TAPPED='1')
assert calls == [
    'list --cask grok-bot', 'list --cask orca', 'uninstall --cask --force orca', 'tap', 'untap stablyai/orca',
], 'an installed orca cask is not uninstalled before its tap is removed'
assert 'removed the orca cask' in log and 'removed the stablyai/orca tap' in log, log
calls, _ = run()
assert calls == ['list --cask grok-bot', 'list --cask orca', 'tap'], 'an absent cask or tap was still removed'
calls, log = run(ORCA='broken')
assert 'untap stablyai/orca' not in calls, 'a tap that is not listed was untapped'
assert 'could not tell whether orca is installed: boom' in log, log
_, log = run(ORCA='installed', TAPPED='1', FAIL='uninstall')
assert 'uninstalling orca failed' in log, log
_, log = run(TAPPED='1', FAIL='untap')
assert 'untapping stablyai/orca failed' in log, log
calls, log = run(TAPPED='1', FAIL='tap')
assert 'untap stablyai/orca' not in calls and 'could not list taps: nope' in log, 'a failed tap listing still untapped'
