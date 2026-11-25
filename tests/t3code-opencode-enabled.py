#!/usr/bin/env python3
"""Check that T3 Code's declared settings enable the opencode instance.

Run by tests/t3code-traits.nix with the packaged scripts/agent-settings and the
declared document a configuration's activation passes to it:

  t3code-opencode-enabled.py MERGER T3CODE_DECLARED

The real merger runs on a settings.json an earlier generation wrote, with the
instance disabled, an OPENCODE_CONFIG_CONTENT entry the owner had set, another
environment entry, and hidden-model preferences for OpenCode. The
merged file must hold the instance enabled with a binary path, replace the
owner's OPENCODE_CONFIG_CONTENT with the one that lists the T3-only instruction
file, keep the other environment entry, leave the preference alone, and drop
the retired provider, also on a second run.

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
        'providers': {'omp': {'enabled': True}},
        'providerInstances': {
            'omp': {'driver': 'acpRegistry', 'enabled': True},
            'opencode': {
                'driver': 'opencode',
                'enabled': False,
                'environment': [
                    {'name': 'KEEP_ME', 'value': '1', 'sensitive': False},
                    {'name': 'OPENCODE_CONFIG_CONTENT', 'value': '{"instructions":["/elsewhere.md"]}', 'sensitive': False},
                ],
            },
        },
        'providerModelPreferences': {
            'omp': {'hiddenModels': ['default']},
            'opencode': {'hiddenModels': ['synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017@low']},
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
            instance = merged.get('providerInstances', {}).get('opencode', {})
            if instance.get('enabled') is not True:
                problems.append('after the {} merge opencode.enabled is {!r}, not True'.format(attempt, instance.get('enabled')))
            binary = instance.get('config', {}).get('binaryPath')
            if not isinstance(binary, str) or not binary.endswith('/bin/opencode'):
                problems.append('after the {} merge opencode.config.binaryPath is {!r}'.format(attempt, binary))
            environment = instance.get('environment', [])
            content = [e for e in environment if e.get('name') == 'OPENCODE_CONFIG_CONTENT']
            if len(content) != 1:
                problems.append('after the {} merge there are {} OPENCODE_CONFIG_CONTENT entries'.format(attempt, len(content)))
            else:
                try:
                    listed = json.loads(content[0]['value']).get('instructions')
                except (ValueError, AttributeError):
                    listed = None
                if (not isinstance(listed, list) or len(listed) != 1
                        or not listed[0].endswith('/.t3/userdata/instructions/opencode.md')):
                    problems.append('after the {} merge OPENCODE_CONFIG_CONTENT lists {!r}'.format(attempt, listed))
            if {'name': 'KEEP_ME', 'value': '1', 'sensitive': False} not in environment:
                problems.append('the {} merge dropped the instance\'s other environment entry'.format(attempt))
            preferences = merged.get('providerModelPreferences', {})
            if preferences.get('opencode') != seeded['providerModelPreferences']['opencode']:
                problems.append('the {} merge changed the owner\'s OpenCode model preference: {!r}'.format(
                    attempt, preferences.get('opencode')))
            for section in ('providerInstances', 'providers', 'providerModelPreferences'):
                if 'omp' in merged.get(section, {}):
                    problems.append(f'{attempt} merge retained the retired provider in {section}')
            if merged.get('unrelated', {}).get('kept') is not True:
                problems.append('the {} merge dropped a key the declaration does not touch'.format(attempt))
    return problems


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: t3code-opencode-enabled.py MERGER T3CODE_DECLARED')
    found = main(*sys.argv[1:])
    for line in found:
        print(line, file=sys.stderr)
    sys.exit(1 if found else 0)
