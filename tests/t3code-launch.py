#!/usr/bin/env python3
"""Execute rendered T3 activation and inspect native launch arguments and files."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def validate(home, expected_opencode_addition):
    settings = json.loads((home / '.t3/userdata/settings.json').read_text())
    baseline = (home / '.claude/CLAUDE.md').read_text()
    assert '# T3 delegation' not in baseline
    assert '# T3 CE model selection' not in baseline
    assert 'writing' in baseline.lower()
    providers = settings['providerInstances']
    assert providers.get('grok') == {'driver': 'grok', 'enabled': False}
    assert not (home / '.t3/userdata/instructions/grok.md').exists()
    args = shlex.split(providers['claudeAgent']['config']['launchArgs'])
    addition = Path(args[args.index('--append-system-prompt-file') + 1]).read_text()
    assert '~/.local/share/nix-config/agent-instructions/t3-guide.md' in addition
    assert '# T3 CE model selection' not in addition
    assert 'writing' not in addition.lower()
    assert not any(a.startswith('--disallowedTools') for a in args)
    assert {'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '', 'sensitive': False} in providers['claudeAgent']['environment']
    # Native discovery reads CLAUDE.md in both launch modes. Only the T3
    # arguments attach an extra file; no native config or CLI wrapper is changed.
    assert baseline + addition != baseline
    pi = shlex.split(providers['pi']['config']['launchArgs'])
    assert Path(pi[pi.index('--append-system-prompt') + 1]).read_text() == addition
    assert providers['pi']['enabled'] is True
    assert pi.count('--approve') == 1
    assert providers['pi']['config']['binaryPath'].endswith('/bin/pi')
    opencode = providers['opencode']
    assert opencode['enabled'] is True and opencode['config']['enabled'] is True
    assert opencode['config']['binaryPath'].endswith('/bin/opencode')
    assert 'launchArgs' not in opencode['config'], 'OpenCode has no launch option for the additions'
    content = [e for e in opencode['environment'] if e['name'] == 'OPENCODE_CONFIG_CONTENT']
    assert len(content) == 1 and content[0]['sensitive'] is False
    listed = json.loads(content[0]['value'])['instructions']
    relative = '.t3/userdata/instructions/opencode.md'
    assert len(listed) == 1 and listed[0].endswith('/' + relative), listed
    assert (home / relative).read_text() == expected_opencode_addition
    assert settings['unrelated'] == {'keep': True}
    assert providers['custom-grok'] == {'driver': 'grok', 'enabled': False}
    assert settings['defaultModelSelection'] == {'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5', 'options': [{'id': 'effort', 'value': 'medium'}]}
    assert settings['fallbackModelSelection'] == {'instanceId': 'pi', 'model': 'synthetic/hf:zai-org/GLM-5.3-Flash', 'options': [{'id': 'thinking', 'value': 'high'}]}
    assert settings['defaultThreadEnvMode'] == 'worktree'
    client = json.loads((home / '.t3/userdata/client-settings.json').read_text())
    assert client['providerModelPreferences']['pi']['hiddenModels'] == [
        'user-hidden', 'default', 'synthetic/infinite:small:vision',
        'synthetic/syn:large:text', 'synthetic/syn:large:vision',
        'synthetic/syn:small:text', 'synthetic/syn:small:vision',
    ]
    assert client['fontFamilyCode'] == client['fontFamilyTerminal'] == 'Jetendard'


def run_activation(entry, home, check=True):
    script = '\n'.join(entry['scripts']).replace(entry['home'], str(home))
    env = dict(os.environ, HOME=str(home))
    env.pop('DRY_RUN', None)
    return subprocess.run(['bash', '-eu', '-c', 'run() { "$@"; };\n' + script],
                          env=env, check=check, capture_output=not check, text=True)


def main():
    manifest = json.loads(Path(sys.argv[1]).read_text())
    for entry in manifest:
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            settings = home / '.t3/userdata/settings.json'
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({
                'unrelated': {'keep': True},
                'providerInstances': {
                    'custom-grok': {'driver': 'grok', 'enabled': False},
                },
            }))
            (settings.parent / 'client-settings.json').write_text(json.dumps({'providerModelPreferences': {
                'pi': {'hiddenModels': ['user-hidden']},
            }}))
            context = home / 'context.json'
            context.write_text(json.dumps({'kind': 'darwin', 'locale': {'name': 'C.UTF-8', 'language': 'en'}}))
            subprocess.run([sys.executable, entry['helper'], '--context', str(context), '--template', entry['template'],
                            '--renderer', entry['renderer'], '--home', scratch], check=True)
            context.write_text(json.dumps({'t3': True, 'opencode': True}))
            expected_opencode_addition = subprocess.check_output(
                [entry['renderer'], entry['template'], str(context)], text=True)
            baseline = (home / '.claude/CLAUDE.md').read_bytes()
            grok_instructions = home / '.grok/AGENTS.md'
            assert not grok_instructions.exists()
            grok_instructions.parent.mkdir()
            grok_instructions.write_text('Existing Grok instructions\n')
            # Pin the normal branch, not merely the absence of a marker.
            assert hashlib.sha256(baseline).hexdigest() == entry['baselineHash']
            for _ in range(2):
                run_activation(entry, home)
                validate(home, expected_opencode_addition)
                assert (home / '.claude/CLAUDE.md').read_bytes() == baseline
                assert grok_instructions.read_text() == 'Existing Grok instructions\n'
            # Mutation witnesses: dropping delivery, baseline contamination,
            # changed defaults, or losing the explicit Grok disable must fail.
            original = settings.read_text()
            mutations = [lambda d: d['providerInstances']['claudeAgent']['config'].update(launchArgs=''),
                         lambda d: d['providerInstances']['pi']['config'].update(launchArgs=d['providerInstances']['pi']['config']['launchArgs'].replace('--approve', '')),
                         lambda d: d.update(defaultThreadEnvMode='local'),
                         lambda d: d['providerInstances'].pop('grok')]
            for mutate in mutations:
                document = json.loads(original)
                mutate(document)
                settings.write_text(json.dumps(document))
                try:
                    validate(home, expected_opencode_addition)
                except (AssertionError, ValueError):
                    pass
                else:
                    raise AssertionError('launch mutation escaped validation')
            settings.write_text(original)
    print('T3 launch activation, instruction files, preferences, and mutation witnesses passed')


if __name__ == '__main__':
    main()
