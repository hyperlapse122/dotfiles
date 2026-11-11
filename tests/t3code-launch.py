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
    args = shlex.split(providers['claudeAgent']['config']['launchArgs'])
    addition = Path(args[args.index('--append-system-prompt-file') + 1]).read_text()
    assert '# T3 delegation' in addition and '# T3 CE model selection' in addition
    assert '| Codex | astra | sol | terra | luna |' in addition
    assert 'writing' not in addition.lower()
    assert 'Agent' in next(a for a in args if a.startswith('--disallowedTools='))
    # Native discovery reads CLAUDE.md in both launch modes. Only the T3
    # arguments attach an extra file; no native config or CLI wrapper is changed.
    assert baseline + addition != baseline
    codex = shlex.split(providers['codex']['config']['launchArgs'])
    assert 'developer_instructions=' in codex[codex.index('-c') + 1]
    assert '--disable' in codex
    pi = shlex.split(providers['pi']['config']['launchArgs'])
    assert Path(pi[pi.index('--append-system-prompt') + 1]).read_text() == addition
    assert providers['pi']['enabled'] is True
    assert pi.count('--approve') == 1
    assert providers['pi']['config']['binaryPath'].endswith('/bin/pi')
    grok = shlex.split(providers['grok'].get('config', {}).get('launchArgs', ''))
    assert not any('prompt' in arg or 'developer_instructions' in arg for arg in grok)
    assert any(e['name'] == 'GROK_SUBAGENTS' and e['value'] == '0' for e in providers['grok']['environment'])
    # The declaration turns the owner's disabled instance on and points it at the
    # wrapper; the owner's own flag survives, and the composer adds nothing.
    antigravity = providers['antigravity']
    assert antigravity['driver'] == 'antigravity' and antigravity['enabled'] is True
    assert antigravity['custom'] is True
    assert antigravity['config']['binaryPath'].endswith('/bin/agy_acp_server.par')
    assert set(antigravity) == {'driver', 'enabled', 'custom', 'config'}
    assert 'omp' not in providers and settings['unrelated'] == {'keep': True}
    assert settings['defaultModelSelection'] == {'instanceId': 'codex', 'model': 'gpt-6.1-sol', 'options': [{'id': 'reasoningEffort', 'value': 'high'}, {'id': 'serviceTier', 'value': 'default'}]}
    assert settings['fallbackModelSelection'] == {'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5'}
    assert settings['textGenerationModelSelection'] == {'instanceId': 'codex', 'model': 'gpt-6-luna'}
    assert settings['defaultThreadEnvMode'] == 'worktree'
    client = json.loads((home / '.t3/userdata/client-settings.json').read_text())
    assert client['providerModelPreferences']['pi']['hiddenModels'] == ['user-hidden', 'default']
    assert client['fontFamilyCode'] == client['fontFamilyTerminal'] == 'Jetendard'


def main():
    manifest = json.loads(Path(sys.argv[1]).read_text())
    for entry in manifest:
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            settings = home / '.t3/userdata/settings.json'
            settings.parent.mkdir(parents=True)
            settings.write_text(json.dumps({'unrelated': {'keep': True}, 'providerInstances': {
                'omp': {'enabled': True}, 'antigravity': {'driver': 'antigravity', 'enabled': False, 'custom': True}}}))
            (settings.parent / 'client-settings.json').write_text(json.dumps({'providerModelPreferences': {'pi': {'hiddenModels': ['user-hidden']}}}))
            context = home / 'context.json'
            context.write_text(json.dumps({'kind': 'darwin', 'locale': {'name': 'C.UTF-8', 'language': 'en'}}))
            subprocess.run([sys.executable, entry['helper'], '--context', str(context), '--template', entry['template'],
                            '--renderer', entry['renderer'], '--home', scratch], check=True)
            baseline = (home / '.claude/CLAUDE.md').read_bytes()
            # Pin the normal branch, not merely the absence of a marker.
            assert hashlib.sha256(baseline).hexdigest() == entry['baselineHash']
            script = '\n'.join(entry['scripts']).replace(entry['home'], scratch)
            env = dict(os.environ, HOME=scratch)
            env.pop('DRY_RUN', None)
            for _ in range(2):
                subprocess.run(['bash', '-eu', '-c', 'run() { "$@"; };\n' + script], env=env, check=True)
                validate(home)
                assert (home / '.claude/CLAUDE.md').read_bytes() == baseline
            # Mutation witnesses: dropping delivery, baseline contamination,
            # changed defaults, or a Grok prompt must fail these assertions.
            original = settings.read_text()
            mutations = [lambda d: d['providerInstances']['claudeAgent']['config'].update(launchArgs=''),
                         lambda d: d['providerInstances']['pi']['config'].update(launchArgs=d['providerInstances']['pi']['config']['launchArgs'].replace('--approve', '')),
                         lambda d: d.update(defaultThreadEnvMode='local'),
                         lambda d: d['providerInstances']['antigravity'].update(enabled=False),
                         lambda d: d['providerInstances']['grok'].update(config={'launchArgs': '--append-system-prompt bad'})]
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
