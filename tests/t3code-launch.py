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


def validate(home):
    settings = json.loads((home / '.t3/userdata/settings.json').read_text())
    baseline = (home / '.claude/CLAUDE.md').read_text()
    assert '# T3 delegation' not in baseline
    assert '# T3 CE model selection' not in baseline
    assert 'writing' in baseline.lower()
    providers = settings['providerInstances']
    assert providers.get('grok') == {'driver': 'grok', 'enabled': False}
    assert 'grok' not in settings.get('providers', {}), 'legacy Grok provider still exists'
    assert not (home / '.t3/userdata/instructions/grok.md').exists()
    args = shlex.split(providers['claudeAgent']['config']['launchArgs'])
    addition = Path(args[args.index('--append-system-prompt-file') + 1]).read_text()
    assert '# T3 delegation' in addition and '# T3 CE model selection' in addition
    assert '| Codex | astra | sol | terra | luna |' in addition
    assert 'writing' not in addition.lower()
    assert not any(a.startswith('--disallowedTools') for a in args)
    assert {'name': 'CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH', 'value': '', 'sensitive': False} in providers['claudeAgent']['environment']
    # Native discovery reads CLAUDE.md in both launch modes. Only the T3
    # arguments attach an extra file; no native config or CLI wrapper is changed.
    assert baseline + addition != baseline
    codex = shlex.split(providers['codex']['config']['launchArgs'])
    assert 'developer_instructions=' in codex[codex.index('-c') + 1]
    assert '--disable' not in codex
    pi = shlex.split(providers['pi']['config']['launchArgs'])
    assert Path(pi[pi.index('--append-system-prompt') + 1]).read_text() == addition
    assert providers['pi']['enabled'] is True
    assert pi.count('--approve') == 1
    assert providers['pi']['config']['binaryPath'].endswith('/bin/pi')
    assert 'omp' not in providers and settings['unrelated'] == {'keep': True}
    assert providers['custom-grok'] == {'driver': 'grok', 'enabled': False}
    assert settings['defaultModelSelection'] == {'instanceId': 'codex', 'model': 'gpt-6.2-sol', 'options': [{'id': 'reasoningEffort', 'value': 'high'}, {'id': 'serviceTier', 'value': 'default'}]}
    assert settings['fallbackModelSelection'] == {'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5'}
    assert settings['textGenerationModelSelection'] == {'instanceId': 'codex', 'model': 'gpt-6-luna'}
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


def exercise_retirement(entry):
    with tempfile.TemporaryDirectory() as scratch:
        home = Path(scratch)
        run_activation(entry, home)
        settings = home / '.t3/userdata/settings.json'
        providers = json.loads(settings.read_text())['providerInstances']
        assert 'antigravity' not in providers, 'fresh settings declare an Antigravity provider'
        assert not (settings.parent / 'instructions/antigravity.md').exists()
        assert not (home / '.gemini/antigravity-acp').exists()

        older_binary = '/nix/store/' + 'a' * 32 + '-antigravity-acp-1.4.5/libexec/antigravity-acp/agy_acp_server.par'
        profile_binary = str(Path(entry['profile']) / 'bin/agy_acp_server.par')
        owned = {'name': 'ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE',
                 'value': str(Path(entry['home']) / '.t3/userdata/instructions/antigravity.md'),
                 'sensitive': False}
        kept = {'name': 'KEEP', 'value': 'user'}
        custom = {'driver': 'antigravity', 'enabled': True,
                  'config': {'binaryPath': '/owner/custom/runtime'}}
        account = home / '.gemini/antigravity-acp'
        account.mkdir(parents=True)
        token = account / 'acp_token.json'
        token.write_text('fake-token')
        for binary in (profile_binary, older_binary):
            # Force the later instruction composer to fail after retirement.
            settings.write_text(json.dumps({'providerInstances': {
                'claudeAgent': {'config': {'launchArgs': '--append-system-prompt-file /missing/append.md'}},
                'antigravity': {'driver': 'antigravity', 'enabled': True,
                                'config': {'binaryPath': binary, 'enabled': True},
                                'environment': [kept, owned], 'custom': True},
                'owner-antigravity': custom,
            }}))
            failure = run_activation(entry, home, check=False)
            assert failure.returncode and 'T3 instruction reconciliation failed' in failure.stderr, failure
            document = json.loads(settings.read_text())
            providers = document['providerInstances']
            assert providers['antigravity'] == {
                'driver': 'antigravity', 'enabled': False, 'config': {'enabled': True},
                'environment': [kept], 'custom': True,
            }
            assert providers['owner-antigravity'] == custom
            assert token.read_text() == 'fake-token'
            providers['claudeAgent']['config'].pop('launchArgs')
            settings.write_text(json.dumps(document))
            run_activation(entry, home)
            assert json.loads(settings.read_text())['providerInstances']['antigravity'] == providers['antigravity']

        custom_registry = {'driver': 'acpRegistry', 'enabled': True, 'config': {'commandPath': '/owner/custom/adapter'}}
        for instance in (custom, custom_registry):
            settings.write_text(json.dumps({'providerInstances': {'antigravity': instance}}))
            run_activation(entry, home)
            assert json.loads(settings.read_text())['providerInstances']['antigravity'] == instance
        legacy_path = home / '.local/share/dotfiles/antigravity-acp/bin/antigravity-acp'
        legacy = {'driver': 'acpRegistry', 'enabled': True, 'config': {'commandPath': str(legacy_path)}}
        settings.write_text(json.dumps({'providerInstances': {'antigravity': legacy}}))
        run_activation(entry, home)
        assert 'antigravity' not in json.loads(settings.read_text())['providerInstances']


def main():
    manifest = json.loads(Path(sys.argv[1]).read_text())
    for entry in manifest:
        exercise_retirement(entry)
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            settings = home / '.t3/userdata/settings.json'
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({
                'unrelated': {'keep': True},
                'providers': {'grok': {'enabled': True}},
                'providerInstances': {
                    'omp': {'enabled': True},
                    'grok': {'driver': 'grok', 'enabled': True,
                             'config': {'binaryPath': '/old/t3-grok-instructions'},
                             'environment': [{'name': 'GROK_DISABLE_AUTOUPDATER', 'value': '1'}]},
                    'custom-grok': {'driver': 'grok', 'enabled': False},
                },
            }))
            (settings.parent / 'client-settings.json').write_text(json.dumps({'providerModelPreferences': {'pi': {'hiddenModels': ['user-hidden']}}}))
            context = home / 'context.json'
            context.write_text(json.dumps({'kind': 'darwin', 'locale': {'name': 'C.UTF-8', 'language': 'en'}}))
            subprocess.run([sys.executable, entry['helper'], '--context', str(context), '--template', entry['template'],
                            '--renderer', entry['renderer'], '--home', scratch], check=True)
            baseline = (home / '.claude/CLAUDE.md').read_bytes()
            grok_instructions = home / '.grok/AGENTS.md'
            assert not grok_instructions.exists()
            grok_instructions.parent.mkdir()
            grok_instructions.write_text('Existing Grok instructions\n')
            # Pin the normal branch, not merely the absence of a marker.
            assert hashlib.sha256(baseline).hexdigest() == entry['baselineHash']
            for _ in range(2):
                run_activation(entry, home)
                validate(home)
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
                    validate(home)
                except (AssertionError, ValueError):
                    pass
                else:
                    raise AssertionError('launch mutation escaped validation')
            settings.write_text(original)
    print('T3 launch activation, instruction files, preferences, and mutation witnesses passed')


if __name__ == '__main__':
    main()
