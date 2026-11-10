#!/usr/bin/env python3
"""Check that T3 Code's declared settings turn an enabled opencode instance off.

Run by tests/t3code-traits.nix with the packaged scripts/agent-settings and the
declared document a configuration's activation passes to it:

  t3code-opencode-disabled.py MERGER T3CODE_DECLARED

T3 Code's built-in opencode instance is already off, so the declared value alone
proves nothing. The real merger runs on a settings.json an earlier generation
wrote, with the instance enabled and the hidden-model preference it declared
for OpenCode: the merged file must hold the instance disabled and the
preference gone, also on a second run, merge "default" into OMP's hiddenModels,
and keep another provider's preference and the keys the declaration does not touch.

Every failure is printed, and the exit status is 1 when there is any.
"""
import json
import os
import subprocess
import sys
import tempfile


def main(merger, declared_path):
    problems = []
    seeded = {
        'unrelated': {'kept': True},
        'providerInstances': {'opencode': {'driver': 'opencode', 'enabled': True}},
        'providerModelPreferences': {
            'opencode': {'hiddenModels': ['synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017@low']},
            'codex': {'hiddenModels': ['gpt-6-luna']},
        },
    }
    with tempfile.TemporaryDirectory() as work:
        target = os.path.join(work, 'settings.json')
        with open(target, 'w') as handle:
            json.dump(seeded, handle)
        os.chmod(target, 0o644)
        for attempt in ('first', 'second'):
            result = subprocess.run(
                [merger, '--label', 't3codeSettings', '--settings', target, '--declared', declared_path,
                 '--ledger', os.path.join(work, 'ownership.json')],
                env={}, capture_output=True, text=True)
            if result.returncode != 0:
                return problems + ['the merger refused the {} run: {}'.format(attempt, result.stderr.strip())]
            with open(target) as handle:
                merged = json.load(handle)
            enabled = merged.get('providerInstances', {}).get('opencode', {}).get('enabled')
            if enabled is not False:
                problems.append('after the {} merge opencode.enabled is {!r}, not False'.format(attempt, enabled))
            preferences = merged.get('providerModelPreferences', {})
            if 'opencode' in preferences:
                problems.append('after the {} merge providerModelPreferences.opencode is still {!r}'.format(
                    attempt, preferences['opencode']))
            if preferences.get('codex') != {'hiddenModels': ['gpt-6-luna']}:
                problems.append('the {} merge changed another provider\'s model preference: {!r}'.format(
                    attempt, preferences.get('codex')))
            if preferences.get('omp') != {'hiddenModels': ['default']}:
                problems.append('after the {} merge providerModelPreferences.omp is {!r}, not hidden default'.format(
                    attempt, preferences.get('omp')))
            if merged.get('unrelated', {}).get('kept') is not True:
                problems.append('the {} merge dropped a key the declaration does not touch'.format(attempt))
    return problems


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: t3code-opencode-disabled.py MERGER T3CODE_DECLARED')
    found = main(*sys.argv[1:])
    for line in found:
        print(line, file=sys.stderr)
    sys.exit(1 if found else 0)
