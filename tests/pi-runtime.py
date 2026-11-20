"""Probe the packaged Pi runtime's model list against the declared OpenAI and Anthropic lists, offline."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

pi, installed, agents = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
PROVIDERS = {'openai': 'openai-responses', 'anthropic': 'anthropic-messages'}


def available(directory, models_json):
    """The models Pi offers with fake credentials for every provider, as its RPC reports them."""
    agent = Path(tempfile.mkdtemp(dir=directory))
    (agent / 'models.json').write_text(json.dumps(models_json))
    (agent / 'auth.json').write_text(json.dumps({
        provider: {'type': 'api_key', 'key': 'FAKE'} for provider in ('synthetic', *PROVIDERS)
    }))
    env = dict(os.environ, HOME=str(agent), PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE='1')
    process = subprocess.Popen([pi, '--offline', '--no-extensions', '--no-session', '--mode', 'rpc'],
                               cwd=agent, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        process.stdin.write((json.dumps({'id': 'models', 'type': 'get_available_models'}) + '\n').encode())
        process.stdin.flush()
        pending = b''
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                if event.get('id') == 'models':
                    assert event['success'], event
                    return {(model['provider'], model['id']): model for model in event['data']['models']}
            if select.select([process.stdout], [], [], 1)[0]:
                chunk = os.read(process.stdout.fileno(), 1 << 20)
                assert chunk, 'Pi exited before listing models: ' + process.stderr.read().decode()
                pending += chunk
        raise AssertionError('Pi did not list its models in time')
    finally:
        process.stdin.close()
        process.kill()
        process.wait()


with tempfile.TemporaryDirectory() as directory:
    configured = json.loads((installed / 'models.json').read_text())
    synthetic = {'synthetic': configured['providers']['synthetic']}
    snapshots = {provider: json.loads((agents / f'{provider}-models.json').read_text())['models']
                 for provider in PROVIDERS}

    # Pi's compiled catalog alone, then with the installed models.json.
    compiled = available(directory, {'providers': synthetic})
    offered = available(directory, configured)

    # The installed models.json declares exactly the listed models Pi's compiled catalog lacks, because a
    # declared row replaces a catalog model and would drop its compat, thinking-level, and cache settings.
    gaps = json.loads((agents / 'pi-catalog-gaps.json').read_text())
    for provider, api in PROVIDERS.items():
        missing = sorted(row['id'] for row in snapshots[provider] if (provider, row['id']) not in compiled)
        assert gaps[provider] == missing, (
            f'pi-catalog-gaps.json lists {gaps[provider]} for {provider} but the compiled catalog lacks {missing}')
        declared = configured['providers'][provider]['models']
        assert sorted(row['id'] for row in declared) == missing, (provider, declared)
        assert all(row['api'] == api and 'baseUrl' not in row for row in declared), declared
        assert 'baseUrl' not in configured['providers'][provider] and 'apiKey' not in configured['providers'][provider]

    # Every listed model is offered once: the declared ones from models.json, the rest from the catalog.
    for provider in PROVIDERS:
        for row in snapshots[provider]:
            assert (provider, row['id']) in offered, f'Pi does not offer {provider}/{row["id"]}'
    for provider, model in (('openai', 'gpt-6.2-sol'), ('openai', 'gpt-6.2-astra')):
        assert (provider, model) not in compiled and (provider, model) in offered, (provider, model)
    for key, model in compiled.items():
        assert offered[key] == model, f'declaring the lists changed the catalog model {key}'
    declared_ids = {(provider, row['id']) for provider in PROVIDERS for row in configured['providers'][provider]['models']}
    for key in declared_ids:
        assert offered[key]['contextWindow'] > 0 and offered[key]['maxTokens'] > 0, key
