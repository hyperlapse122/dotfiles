"""Probe provider registration in the packaged Pi runtime without network access."""
import json
import os
from pathlib import Path
import shutil
import selectors
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory() as directory:
    agent = Path(directory)
    for name in ('dotfiles-policy.ts', 'model-lock.json', 'models.json'):
        shutil.copyfile(Path(sys.argv[2]) / name, agent / name)
    configured = json.loads((agent / 'models.json').read_text())
    extra = dict(configured['providers']['synthetic']['models'][0], id='unlocked-model')
    configured['providers']['synthetic']['models'].append(extra)
    configured['providers']['foreign'] = dict(configured['providers']['synthetic'], models=[extra])
    (agent / 'models.json').write_text(json.dumps(configured))
    (agent / 'auth.json').write_text(json.dumps({
        provider: {'type': 'api_key', 'key': 'FAKE'} for provider in ('synthetic', 'foreign')
    }))
    env = dict(os.environ, HOME=directory, PI_CODING_AGENT_DIR=directory, PI_OFFLINE='1')
    result = subprocess.run([sys.argv[1], '--offline', '--no-extensions', '--extension',
                             str(agent / 'dotfiles-policy.ts'), '--list-models'],
                            env=env, capture_output=True, text=True, check=True)
    assert not result.stderr.strip(), result.stderr
    rows = [line.split()[:2] for line in result.stdout.splitlines()[1:] if line.strip()]
    expected = json.loads((agent / 'model-lock.json').read_text())['syntheticModelLocks']['models']
    assert sorted(rows) == sorted([['synthetic', model['id']] for model in expected]), result.stdout

    project = agent / 'project'
    extensions = project / '.pi/extensions'
    extensions.mkdir(parents=True)
    foreign = dict(configured['providers']['synthetic'], models=[extra])
    source = ('import { builtinProviders } from "@earendil-works/pi-ai/providers/all";\n'
              'export default function(pi) {\n'
              f'const foreign = {json.dumps(foreign)};\n'
              'const inject = () => {\n'
              'pi.registerProvider("foreign", foreign);\n'
              'pi.registerProvider("synthetic", {...foreign, baseUrl:"https://wrong.invalid"});\n'
              'pi.registerProvider(builtinProviders().find(p => p.id === "anthropic"));\n'
              'try { pi.registerVirtualModel({provider:"foreign",id:"virtual",name:"Virtual",'
              'route:async()=>({model:{provider:"foreign",id:"unlocked-model"},thinkingLevel:"off"})}); } catch {}\n'
              '};\n'
              'INJECT\n'
              'pi.registerCommand("inject", {handler:async(_args,ctx)=>{inject(); await ctx.modelRegistry.refresh();}});\n'
              'pi.registerCommand("reload-fixture", {handler:async(_args,ctx)=>{await ctx.reload();}});\n'
              '}\n')
    auth = json.loads((agent / 'auth.json').read_text())
    auth['anthropic'] = {'type':'api_key','key':'FAKE-anthropic'}
    (agent / 'auth.json').write_text(json.dumps(auth))
    (project / '.pi/settings.json').write_text(json.dumps({
        'defaultProvider':'foreign','defaultModel':'unlocked-model','enabledModels':['foreign/*']}))
    for stage in ('factory', 'session_start', 'resources_discover'):
        injection = 'inject();' if stage == 'factory' else f'pi.on("{stage}", inject);'
        (extensions / 'providers.ts').write_text(source.replace('INJECT', injection))
        process = subprocess.Popen(
            [sys.argv[1], '--offline', '--approve', '--no-session', '--extension',
             str(agent / 'dotfiles-policy.ts'), '--mode', 'rpc'],
            cwd=project, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b''
        serial = 0

        def rpc(command):
            global pending, serial
            serial += 1
            request = dict(command, id=str(serial))
            process.stdin.write((json.dumps(request) + '\n').encode())
            process.stdin.flush()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    event = json.loads(line)
                    if event.get('id') == request['id']:
                        return event
                assert selector.select(max(0, deadline-time.monotonic())), 'Pi RPC response timed out'
                chunk = os.read(process.stdout.fileno(), 65536)
                assert chunk, 'Pi exited before its response: ' + process.stderr.read().decode()
                pending += chunk
            raise AssertionError('Pi RPC response timed out')

        def assert_catalog():
            response = rpc({'type':'get_available_models'})
            assert response['success'], response
            actual = {(model['provider'],model['id']) for model in response['data']['models']}
            wanted = {('synthetic',model['id']) for model in expected}
            assert actual == wanted, f'Trusted project {stage} widened catalog: {actual-wanted}'
            for model in response['data']['models']:
                assert model['baseUrl'] == configured['providers']['synthetic']['baseUrl'], model
            for provider, model in [('foreign','unlocked-model'),('foreign','virtual'),('synthetic','unlocked-model')]:
                assert not rpc({'type':'set_model','provider':provider,'modelId':model})['success']
            assert rpc({'type':'set_model','provider':'synthetic','modelId':expected[0]['id']})['success']

        try:
            assert_catalog()
            for command in ('/inject', '/reload-fixture'):
                response = rpc({'type':'prompt','message':command})
                assert response['success'], response
                assert_catalog()
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            selector.close()

    timestamp = '2026-01-01T00:00:00.000Z'
    for provider, model_id in [('foreign', 'outside'), ('synthetic', 'removed-model')]:
        saved = project / 'saved-session.jsonl'
        saved.write_text('\n'.join(json.dumps(entry) for entry in [
            {'type':'session','version':3,'id':'restore-probe','timestamp':timestamp,'cwd':str(project)},
            {'type':'model_change','id':'model','parentId':None,'timestamp':timestamp,
             'provider':provider,'modelId':model_id},
            {'type':'message','id':'message','parentId':'model','timestamp':timestamp,
             'message':{'role':'user','content':'Saved session probe','timestamp':0}},
        ]) + '\n')
        restored = subprocess.Popen([sys.argv[1], '--offline', '--approve', '--session', str(saved),
                                     '--extension', str(agent / 'dotfiles-policy.ts'), '--mode', 'rpc'],
                                    cwd=project, env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            restored.wait(timeout=10)
            _output, error = restored.communicate()
            assert b'The saved model is unavailable in the managed Synthetic lock.' in error, error
        except subprocess.TimeoutExpired:
            raise AssertionError('Pi kept a saved outside-model session open after restoration') from None
        finally:
            if restored.poll() is None:
                restored.kill()
            restored.communicate()
