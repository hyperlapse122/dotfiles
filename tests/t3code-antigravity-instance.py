#!/usr/bin/env python3
"""Check the Antigravity instance T3 Code's declared settings carry.

Run by tests/t3code-traits.nix with the packaged scripts/agent-settings and the
declared document a configuration's activation passes to it:

  t3code-antigravity-instance.py MERGER T3CODE_DECLARED T3_DIR PATH_DIR EXECUTABLE HARNESS

T3_DIR is libexec/antigravity-acp of the runtime built from the pinned T3 Code's
embedded release, PATH_DIR the same directory of the runtime behind the PATH
wrapper, or "-" when both pin the same release and the runtimes coincide, and EXECUTABLE and HARNESS the file names the pin records for the two
binaries T3_DIR holds. The declared instance must be enabled and name the
executable in T3_DIR by absolute store path: not a bare command name that
resolves through PATH, not a file under ~/.t3/tools, and not the PATH runtime
when the pins differ. T3 Code finds the harness beside the executable, so the
pin must name both. The real merger then runs on a settings.json that already
holds an antigravity instance with app state: the merged file must keep that
state, hold the declared path and enabled, also on a second run.

Every failure is printed, and the exit status is 1 when there is any.
"""
import json
import os
import subprocess
import sys
import tempfile


def main(merger, declared_path, t3_dir, path_dir, executable, harness):
    problems = []
    with open(declared_path) as handle:
        declared = json.load(handle)
    leaves = {tuple(row['path'][2:]): row['value'] for row in declared.get('setPaths', [])
              if row['path'][:2] == ['providerInstances', 'antigravity']}
    if leaves.get(('driver',)) != 'antigravity':
        problems.append('the antigravity instance declares driver {!r}'.format(leaves.get(('driver',))))
    if leaves.get(('enabled',)) is not True:
        problems.append('the antigravity instance declares enabled {!r}'.format(leaves.get(('enabled',))))
    binary = leaves.get(('config', 'binaryPath'))
    if binary != '{}/{}'.format(t3_dir, executable):
        problems.append('binaryPath {!r} is not {} inside the T3-pinned runtime {}'.format(
            binary, executable, t3_dir))
    if not isinstance(binary, str) or not binary.startswith('/nix/store/') or '.t3/tools' in binary:
        problems.append('binaryPath {!r} is not a Nix store path, so it may resolve through PATH or ~/.t3/tools'.format(binary))
    if path_dir != '-' and isinstance(binary, str) and binary.startswith(path_dir + '/'):
        problems.append('binaryPath {!r} names the PATH runtime, not the T3-pinned one'.format(binary))
    if (executable, harness) != ('agy_acp_server.par', 'localharness_external'):
        problems.append('the pin names {} and {}, not the agy_acp_server.par and localharness_external T3 Code looks for'.format(
            executable, harness))

    seeded = {
        'providerInstances': {
            'antigravity': {
                'driver': 'antigravity',
                'enabled': False,
                'displayName': 'My Antigravity',
                'config': {'binaryPath': '/stale/agy_acp_server.par', 'env': {'KEEP': 'yes'}},
            },
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
            instance = merged.get('providerInstances', {}).get('antigravity')
            if instance is None:
                problems.append('the {} merge removed the existing antigravity instance'.format(attempt))
                continue
            if instance.get('enabled') is not True or instance.get('config', {}).get('binaryPath') != binary:
                problems.append('after the {} merge the antigravity instance is {!r}, not the declared one'.format(
                    attempt, instance))
            if instance.get('displayName') != 'My Antigravity' or instance.get('config', {}).get('env') != {'KEEP': 'yes'}:
                problems.append('the {} merge dropped app state of the antigravity instance: {!r}'.format(
                    attempt, instance))
    return problems


if __name__ == '__main__':
    if len(sys.argv) != 7:
        sys.exit('usage: t3code-antigravity-instance.py MERGER T3CODE_DECLARED T3_DIR PATH_DIR EXECUTABLE HARNESS')
    found = main(*sys.argv[1:])
    for line in found:
        print(line, file=sys.stderr)
    sys.exit(1 if found else 0)
