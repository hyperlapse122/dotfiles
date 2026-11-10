"""Run home.activation.antigravitySkillsRetire in a scratch HOME.

Usage: antigravity-skills-retire.py SCRIPT ORIGINAL_HOME HOME_FILES BASH

The packaged agy the script names is replaced with a stub that records its
arguments, so the uninstall is observed without a real Antigravity install.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

script_path, original_home, home_files, bash = sys.argv[1:]
script = Path(script_path).read_text()
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


agys = set(re.findall(r'/nix/store/[^\s\'";]+/bin/agy', script))
assert len(agys) == 1, f'the step must name one packaged agy, found {sorted(agys)}'
agy = agys.pop()
assert original_home.startswith('/') and original_home != '/', 'unsafe home replacement'
assert original_home in script, 'the step does not name the user home'

root_rel = '.gemini/antigravity-cli/skills'
retired_rel = '.gemini/config/plugins/compound-engineering'
# A skill the retired linker linked and this configuration declares, so the
# removed link's name is one checkLinkTargets would otherwise find occupied.
retired_skill = 'ce-plan'
check((Path(home_files) / root_rel / retired_skill / 'SKILL.md').is_file(),
      f'~/{root_rel}/{retired_skill} is not declared, so nothing replaces the retired link')

with tempfile.TemporaryDirectory() as directory:
    scratch = Path(directory)
    log = scratch / 'agy.log'
    stub = scratch / 'agy'
    stub.write_text('#!' + bash + '\nprintf "%s\\n" "$*" >> "$AGY_LOG"\nexit "${AGY_STATUS:-0}"\n')
    stub.chmod(0o755)

    def run(seed_plugin=True, status=0, dry=False):
        home = scratch / 'home'
        if home.exists():
            subprocess.run(['rm', '-rf', str(home)], check=True)
        root = home / root_rel
        root.mkdir(parents=True)
        plugin = home / retired_rel
        if seed_plugin:
            (plugin / 'skills' / retired_skill).mkdir(parents=True)
        (root / retired_skill).symlink_to(plugin / 'skills' / retired_skill)
        (root / 'mine').symlink_to(scratch / 'elsewhere')
        (root / 'notes.txt').write_text('user content\n')
        (root / 'test-audit').symlink_to('/nix/store/0000000000000000000000000000000-home-manager-files/x')
        log.unlink(missing_ok=True)
        redirected = script.replace(original_home, str(home)).replace(agy, str(stub))
        block = scratch / 'block.sh'
        block.write_text('run() { if [[ -z ${DRY_RUN:-} ]]; then "$@"; fi; }\n' + redirected)
        env = dict(os.environ, HOME=str(home), AGY_LOG=str(log), AGY_STATUS=str(status))
        env.pop('DRY_RUN', None)
        if dry:
            env['DRY_RUN'] = '1'
        result = subprocess.run([bash, '-euo', 'pipefail', str(block)], env=env, cwd=home,
                                capture_output=True, text=True)
        calls = log.read_text().splitlines() if log.exists() else []
        return result, root, calls

    result, root, calls = run()
    check(result.returncode == 0, f'the step failed: {result.stderr}')
    check(not os.path.lexists(root / retired_skill), 'the retired plugin link survived')
    check((root / 'mine').is_symlink(), 'a link to another target was removed')
    check((root / 'notes.txt').is_file(), 'a regular file was removed')
    check((root / 'test-audit').is_symlink(), 'a store link was removed')
    check(str(root / 'mine') in result.stderr, 'the kept foreign link was not reported')
    check(str(root / 'notes.txt') in result.stderr, 'the kept regular file was not reported')
    check(calls == ['plugin uninstall compound-engineering'],
          f'agy must be called once to uninstall the plugin, got {calls}')

    result, root, calls = run(status=3)
    check(result.returncode == 0, f'a failing uninstall failed the apply: {result.stderr}')
    check(calls == ['plugin uninstall compound-engineering'], f'failing uninstall calls: {calls}')
    check('failed' in result.stderr, 'a failing uninstall was not reported')
    check(not os.path.lexists(root / retired_skill), 'a failing uninstall kept the retired link')

    result, root, calls = run(seed_plugin=False)
    check(result.returncode == 0, f'the step failed without a plugin copy: {result.stderr}')
    check(calls == [], f'agy ran with no plugin copy present: {calls}')
    check(not os.path.lexists(root / retired_skill), 'a dangling retired link survived')

    result, root, calls = run(dry=True)
    check(result.returncode == 0, f'the dry run failed: {result.stderr}')
    check(os.path.lexists(root / retired_skill), 'the dry run removed a link')
    check(calls == [], f'the dry run ran agy: {calls}')

for failure in failures:
    print(failure, file=sys.stderr)
sys.exit(1 if failures else 0)
