import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

def assert_types(actual, expected):
    assert type(actual) is type(expected), 'activation changed consumer value type'
    if isinstance(expected, dict):
        for key, value in expected.items():
            assert_types(actual[key], value)
    elif isinstance(expected, list):
        assert len(actual) == len(expected)
        for value, want in zip(actual, expected):
            assert_types(value, want)


def value_at(document, path):
    for key in path:
        document = document[key]
    return document


mode, script_path, original_home, contract_path, bash = sys.argv[1:]
script = Path(script_path).read_text()
contract = json.loads(Path(contract_path).read_text())
helper_name = 'agent-settings' if mode == 'settings' else 'agent-plugin-sync'
helpers = set(re.findall(r'/nix/store/[^\s\'";]+/bin/' + helper_name, script))
assert len(helpers) == 1, 'activation must name one packaged ' + helper_name
helper = helpers.pop()
assert original_home.startswith('/') and original_home != '/', 'unsafe home replacement'
assert original_home in script, 'activation destination was not redirected'

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    home = root / 'home'
    home.mkdir()
    redirected = script.replace(original_home, str(home))
    assert redirected != script and original_home not in redirected
    recorder = root / 'record'
    log = root / 'calls.jsonl'
    recorder.write_text('#!' + sys.executable + '\n' + '''import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ['ACTIVATION_LOG'], 'a') as stream:
    stream.write(json.dumps({'args': args, 'codex_home': os.environ.get('CODEX_HOME'),
                             'updater': os.environ.get('DISABLE_AUTOUPDATER')}) + '\\n')
if os.environ.get('FAIL_HARNESS') == ('settings' if '--harness' not in args else args[args.index('--harness') + 1]):
    sys.exit(73)
if os.environ['ACTIVATION_MODE'] == 'settings':
    sys.exit(subprocess.call([os.environ['ACTIVATION_HELPER'], *args]))
''')
    recorder.chmod(0o755)
    redirected = redirected.replace(helper, shlex.quote(str(recorder)))
    block = root / 'block.sh'
    block.write_text('run() { if [[ -z ${DRY_RUN:-} ]]; then "$@"; fi; }\n' + redirected)
    env = dict(os.environ, HOME=str(home), ACTIVATION_LOG=str(log),
               ACTIVATION_HELPER=helper, ACTIVATION_MODE=mode,
               CODEX_HOME=str(root / 'inherited-codex'))
    env.pop('DRY_RUN', None)

    def run(fail=None, dry=False):
        log.unlink(missing_ok=True)
        current = dict(env)
        if fail:
            current['FAIL_HARNESS'] = fail
        if dry:
            current['DRY_RUN'] = '1'
        result = subprocess.run([bash, '-euo', 'pipefail', str(block)], env=current, cwd=home,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    if mode == 'settings':
        target = home / contract['file']
        target.parent.mkdir(parents=True, exist_ok=True)
        declared = contract['declared']
        seed = {'activationUnmanaged': 'keep'}
        for key, value in declared.get('set', {}).items():
            seed[key] = not value if isinstance(value, bool) else 'divergent'
        for row in declared.get('setPaths', []):
            parent = seed
            for key in row['path'][:-1]:
                parent = parent.setdefault(key, {})
            parent[row['path'][-1]] = not row['value'] if isinstance(row['value'], bool) else 'divergent'
        for key in declared.get('remove', []):
            seed[key] = 'retired'
        seed = contract.get('seed', seed)
        toml = contract.get('format') == 'toml'
        if toml:
            import tomlkit
            target.write_text(seed if isinstance(seed, str) else tomlkit.dumps(seed))
        else:
            target.write_text(json.dumps(seed))
        seeded_bytes = target.read_bytes()
        seeded_files = sorted(str(path.relative_to(home)) for path in home.rglob('*'))
        result, calls = run(dry=True)
        assert result.returncode == 0, result.stderr
        assert not calls, 'settings dry-run invoked a writing helper'
        assert target.read_bytes() == seeded_bytes, 'settings dry-run changed protected bytes'
        assert sorted(str(path.relative_to(home)) for path in home.rglob('*')) == seeded_files, 'settings dry-run created state'
        result, calls = run()
        assert result.returncode == 0, result.stderr
        assert len(calls) == 1, 'activation did not execute exactly one merger'
        args = calls[0]['args']
        assert args[args.index('--settings') + 1] == str(target), 'wrong activation destination'
        delivered = json.loads(Path(args[args.index('--declared') + 1]).read_text())
        assert {key: value for key, value in delivered.items() if key != 'ownEntries'} == {
            key: value for key, value in declared.items() if key != 'ownEntries'
        }, 'wrong activation declaration'
        expected_entries = declared.get('ownEntries', [])
        delivered_entries = delivered.get('ownEntries', [])
        # Entry contracts may cover only independently specified fields; runtime
        # command owners check arguments without pinning generated store names.
        assert len(delivered_entries) == len(expected_entries), 'wrong owned declaration entries'
        for row, expected in zip(delivered_entries, expected_entries):
            assert row['path'] == expected['path'], 'wrong owned declaration path'
            for key, value in expected['entries'].items():
                assert_types(row['entries'][key], value)
                assert row['entries'][key] == value, 'wrong owned declaration value: ' + key
        if toml:
            assert args[args.index('--format') + 1] == 'toml'
        applied_bytes = target.read_bytes()
        applied_text = applied_bytes.decode()
        actual = tomlkit.parse(applied_text).unwrap() if toml else json.loads(applied_text)
        if 'expected' in contract:
            assert_types(actual, contract['expected'])
            assert actual == contract['expected'], 'activation did not preserve the seeded document'
        elif 'preservePaths' not in contract:
            assert actual['activationUnmanaged'] == 'keep', 'activation lost unmanaged state'
        for key, value in (declared.get('set', {}) | declared.get('own', {})).items():
            assert_types(actual[key], value)
            assert actual[key] == value, 'activation did not reassert ' + key
        for row in declared.get('setPaths', []):
            value = value_at(actual, row['path'])
            assert_types(value, row['value'])
            assert value == row['value'], 'activation did not reassert nested setting'
        for row in expected_entries:
            entries = value_at(actual, row['path'])
            for key, value in row['entries'].items():
                assert_types(entries[key], value)
                assert entries[key] == value, 'activation did not reassert owned entry: ' + key
        for key in declared.get('remove', []):
            assert key not in actual, 'activation did not retire ' + key
        for path in contract.get('preservePaths', []):
            value, want = value_at(actual, path), value_at(seed, path)
            assert_types(value, want)
            assert value == want, 'activation changed unmanaged path: ' + '.'.join(path)
        if toml:
            for line in seeded_bytes.decode().splitlines():
                if line.lstrip().startswith('#'):
                    assert line in applied_text, 'activation lost a user comment'
        result, calls = run()
        assert result.returncode == 0 and len(calls) == 1, 'repeated activation failed'
        assert target.read_bytes() == applied_bytes, 'repeated activation changed settings'
        if target.parent != home:
            shutil.rmtree(target.parent)
        else:
            target.unlink()
        result, calls = run()
        assert result.returncode == 0 and len(calls) == 1, 'absent-file activation failed'
        assert target.is_file() and (target.stat().st_mode & 0o777) == 0o600, 'absent-file mode is not 0600'
        result, calls = run('settings')
        assert calls and result.returncode != 0, 'activation swallowed merger refusal'
    else:
        result, calls = run()
        assert result.returncode == 0, result.stderr
        assert len(calls) == len(contract), 'activation skipped plugin harness rows'
        for call, expected in zip(calls, contract):
            args = call['args']
            for flag, value in expected.items():
                value = value.replace(original_home, str(home))
                assert args[args.index('--' + flag) + 1] == value, 'wrong runtime plugin ' + flag
            assert '--accept-command' not in args
            if expected['harness'] == 'codex':
                assert call['codex_home'] is None, 'Codex inherited CODEX_HOME'
            if expected['harness'] == 'claude':
                assert call['updater'] == '1', 'Claude updater environment missing'
        for row in contract:
            result, calls = run(row['harness'])
            assert any(c['args'][c['args'].index('--harness') + 1] == row['harness'] for c in calls)
            assert result.returncode != 0, 'activation swallowed plugin refusal: ' + row['harness']
        result, calls = run(dry=True)
        assert result.returncode == 0 and len(calls) == len(contract), 'dry-run skipped plugin rows'
        assert all('--dry-run' in call['args'] for call in calls), 'dry-run reached a writing plugin row'
