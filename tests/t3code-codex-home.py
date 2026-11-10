#!/usr/bin/env python3
"""Check that every declared T3 Code Codex instance runs on ~/.codex.

Run by tests/t3code-traits.nix with the settings.json declaration a
configuration's activation passes to the merger:

  t3code-codex-home.py T3CODE_DECLARED

T3 Code picks a Codex instance's home from config.homePath,
config.shadowHomePath, and config.setupMode, and the merge keeps every field
the module does not declare, so a home set in the app would survive every
apply. An empty homePath is not enough: T3 Code sets CODEX_HOME only for a
nonempty homePath, so a CODEX_HOME in the instance's environment, which the
merge keeps too, would still choose the home. Every provider instance whose
declared driver is "codex" must therefore declare config.homePath as
"~/.codex", which T3 Code expands to the home where the plugin sync and the
skills land, and config.setupMode as a value
other than "managed", which would give the instance a home of T3 Code's own.
At least one such instance must be declared.

Every failure is printed, and the exit status is 1 when there is any.
"""
import json
import sys


def main():
    with open(sys.argv[1]) as handle:
        declared = json.load(handle)

    instances = {}
    for entry in declared.get('setPaths', []):
        path = entry.get('path', [])
        if len(path) >= 3 and path[0] == 'providerInstances':
            instances.setdefault(path[1], {})[tuple(path[2:])] = entry.get('value')

    failures = []
    codex = [name for name, leaves in sorted(instances.items()) if leaves.get(('driver',)) == 'codex']
    if not codex:
        failures.append('no provider instance declares driver "codex"')
    for name in codex:
        leaves = instances[name]
        home = ('config', 'homePath')
        if home not in leaves:
            failures.append(f'the {name} instance declares no config.homePath, so a home set in the app survives every apply')
        elif leaves[home] != '~/.codex':
            failures.append(f'the {name} instance declares config.homePath {leaves[home]!r}, not "~/.codex", so its sessions can leave ~/.codex')
        mode = ('config', 'setupMode')
        if mode not in leaves:
            failures.append(f'the {name} instance declares no config.setupMode, so a managed setup set in the app survives every apply')
        elif leaves[mode] == 'managed':
            failures.append(f'the {name} instance declares config.setupMode "managed", which runs it on a home of T3 Code\'s own')

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
