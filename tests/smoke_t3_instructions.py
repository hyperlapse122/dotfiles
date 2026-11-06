"""Verify native launch additions with a controlled local model transport.

Fixture model replies only drive native lifecycle transitions. They are not
authenticated model completions, and never contain the instruction markers.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from urllib.parse import urlsplit

from asset_fixtures import copy_asset_templates, run_with_assets
from smoke_codex import AppServer, strings
from smoke_personal_apps import REPO, executable, temporary_destination

sys.path.insert(0, str(REPO / 'scripts'))

def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), REPO / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


instructions = module('t3-instructions')
pi_settings = module('pi-settings')


@contextmanager
def model_transport():
    records = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, body, content_type='application/json'):
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def events(self, events):
            self.respond(''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n'
                                 for event in events).encode(), 'text/event-stream')

        def do_GET(self):
            self.respond({'object': 'list', 'data': [{'id': 'gpt-5.1-codex', 'object': 'model'}]})

        def do_POST(self):
            self.path = urlsplit(self.path).path
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            records.append((self.path, body))
            if self.path.endswith('/count_tokens'):
                self.respond({'input_tokens': 10})
            elif self.path.endswith('/compact'):
                self.respond({'id': 'cmp_fixture', 'object': 'response.compaction', 'created_at': int(time.time()),
                              'output': [{'type': 'compaction', 'encrypted_content': 'opaque-fixture-summary'}],
                              'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12}})
            elif self.path.endswith('/responses'):
                item = {'type': 'message', 'id': 'msg_fixture', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'Fixture response.', 'annotations': []}]}
                response = {'id': 'resp_fixture', 'object': 'response', 'status': 'completed',
                            'model': body.get('model', 'gpt-5.1-codex'), 'output': [item],
                            'usage': {'input_tokens': 10, 'output_tokens': 2, 'total_tokens': 12,
                                      'input_tokens_details': {'cached_tokens': 0}}}
                self.events([{'type': 'response.created', 'response': {**response, 'status': 'in_progress', 'output': []}},
                             {'type': 'response.output_item.added', 'output_index': 0,
                              'item': {**item, 'status': 'in_progress', 'content': []}},
                             {'type': 'response.output_text.delta', 'item_id': 'msg_fixture', 'output_index': 0,
                              'content_index': 0, 'delta': 'Fixture response.'},
                             {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                             {'type': 'response.completed', 'response': response}])
            elif self.path.endswith('/messages'):
                self.events([
                    {'type': 'message_start', 'message': {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant',
                        'model': body.get('model'), 'content': [], 'stop_reason': None, 'stop_sequence': None,
                        'usage': {'input_tokens': 10, 'output_tokens': 0}}},
                    {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                    {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Fixture response.'}},
                    {'type': 'content_block_stop', 'index': 0},
                    {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None},
                     'usage': {'output_tokens': 2}}, {'type': 'message_stop'}])
            elif self.path.endswith('/chat/completions'):
                first = {'id': 'chat_fixture', 'object': 'chat.completion.chunk', 'created': int(time.time()),
                         'model': body.get('model'), 'choices': [{'index': 0, 'delta': {'role': 'assistant',
                         'content': 'Fixture response.'}, 'finish_reason': None}]}
                last = {**first, 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
                        'usage': {'prompt_tokens': 10, 'completion_tokens': 2, 'total_tokens': 12}}
                self.respond(('data: ' + json.dumps(first) + '\n\ndata: ' + json.dumps(last)
                              + '\n\ndata: [DONE]\n\n').encode(), 'text/event-stream')
            else:
                self.respond({})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/v1', records
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def run(command, env, cwd, timeout=90):
    result = subprocess.run(list(map(str, command)), env=env, cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError('Native fixture command failed: ' + result.stdout[-1200:] + result.stderr[-1200:])
    return result.stdout


def check_context(payload, harness, addition, *, existing=False):
    text = '\n'.join(strings(payload)).replace('\r\n', '\n')
    for marker in ('NATIVE_COMMON_71AE', 'NATIVE_EXISTING_USER_98D1', 'NATIVE_' + harness.upper() + '_9F26', 'NATIVE_REPOSITORY_41D2'):
        if text.count(marker) != 1:
            raise RuntimeError('Native ' + harness + ' context must contain exactly one ' + marker)
    if ('T3_ONLY_6C32' in text) != addition:
        raise RuntimeError('Native ' + harness + ' leaked or omitted the per-launch T3 addition.')
    if 'FOREIGN_HARNESS_B8C1' in text:
        raise RuntimeError('Native context includes a foreign harness branch.')
    if existing and 'EXISTING_' + harness.upper() + '_LAUNCH' not in text:
        raise RuntimeError('Native context discarded existing launch instructions.')


def codex_turn(binary, arguments, env, cwd, log, records, *, addition):
    start = len(records)
    phase = 'PHASE_' + log.name
    with log.open('w', encoding='utf-8') as stderr:
        server = AppServer([str(binary), '-c', 'cli_auth_credentials_store="file"', 'app-server', *arguments], env, cwd, stderr)
        try:
            server.request('initialize', {'clientInfo': {'name': 'dotfiles-launch-proof', 'version': '1'},
                                           'capabilities': {'experimentalApi': True}})
            server.send({'method': 'initialized', 'params': {}})
            skills = server.request('skills/list', {'cwds': [str(cwd)], 'forceReload': True})
            skill = next(item for group in skills['data'] for item in group['skills']
                         if item['name'].endswith(':ce-noslop') and item.get('enabled'))
            thread = server.request('thread/start', {'cwd': str(cwd), 'approvalPolicy': 'never', 'sandbox': 'read-only'})
            server.request('turn/start', {'threadId': thread['thread']['id'], 'input': [
                {'type': 'skill', 'name': skill['name'], 'path': skill['path']},
                {'type': 'text', 'text': phase + ' Reply with the fixture response; execute no tools.', 'textElements': []}]})
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if server.receive(max(.1, deadline - time.monotonic())).get('method') == 'turn/completed':
                    break
        except Exception as error:
            stderr.flush()
            raise RuntimeError('Native Codex lifecycle fixture failed: ' + log.read_text(encoding='utf-8')[-2200:]) from error
        finally:
            server.close()
    requests = [body for path, body in records[start:] if path.endswith('/responses') and phase in '\n'.join(strings(body))]
    if not requests:
        raise RuntimeError('Codex did not reach the controlled native model transport.')
    check_context(requests[-1], 'codex', addition, existing=addition)
    if 'Write without slop' not in '\n'.join(strings(requests[-1])):
        raise RuntimeError('Native Codex CE invocation was not preserved.')


def t3_turns(root, home, cwd, env, target, install_desktop, records):
    from smoke_antigravity import desktop_command
    from smoke_t3_code import T3Rpc, WindowsProcessJob, provision_desktop
    real_env = os.environ.copy()
    if install_desktop:
        provision_desktop(target, root, real_env)
    command = desktop_command(Path(real_env.get('USERPROFILE', real_env.get('HOME', ''))), real_env)
    settings_path = home / '.t3/userdata/settings.json'
    settings = json.loads(settings_path.read_text())
    for name, provider in settings['providerInstances'].items():
        if name not in ('codex', 'claudeAgent', 'pi'):
            provider['enabled'] = False
            provider.setdefault('config', {})['enabled'] = False
    settings_path.write_text(json.dumps(settings))
    env = {**env, 'ELECTRON_RUN_AS_NODE': '1', 'T3CODE_DESKTOP_CLI_LAUNCHER': '1',
           'T3CODE_HOME': str(home / '.t3'),
           'T3CODE_CODEX_LAUNCH_ARGS': '-c developer_instructions=INCORRECT_INHERITED_OVERRIDE'}
    env['PATH'] = os.pathsep.join(part for part in env.get('PATH', '').split(os.pathsep)
                                if '.local/bin' not in part.replace('\\', '/').lower())
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    token = run(command + ['auth', 'session', 'issue', '--base-dir', str(home / '.t3'),
                           '--ttl', '10m', '--token-only'], env, cwd).strip()
    job = WindowsProcessJob() if os.name == 'nt' else None
    with (root / 't3-server.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen(command + ['serve', '--mode', 'desktop', '--host', '127.0.0.1',
            '--port', str(port), '--base-dir', str(home / '.t3'), '--no-browser'], env=env, cwd=cwd,
            stdout=log, stderr=subprocess.STDOUT, start_new_session=os.name != 'nt')
        if job:
            job.assign(process)
        rpc = None
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Disposable T3 exited during startup.')
                try:
                    rpc = T3Rpc(port, token)
                    break
                except OSError:
                    time.sleep(.1)
            if rpc is None:
                raise RuntimeError('Disposable T3 did not start.')
            sequence = 0
            def call(method, payload):
                nonlocal sequence
                sequence += 1
                return rpc.call(str(sequence), method, payload)
            def dispatch(kind, **fields):
                return call('orchestration.dispatchCommand', {'type': kind, 'commandId': str(uuid.uuid4()), **fields})
            project_id = str(uuid.uuid4())
            call('projects.mutate', {'type': 'project.create', 'commandId': str(uuid.uuid4()),
                 'projectId': project_id, 'title': 'Disposable instruction proof', 'workspaceRoot': str(cwd)})
            for provider, harness, model in (('codex', 'codex', 'gpt-5.1-codex'),
                                              ('claudeAgent', 'claude', 'claude-sonnet-4-6'),
                                              ('pi', 'pi', 'default')):
                snapshot = call('server.refreshProviders', {'instanceId': provider, 'cwd': str(cwd),
                                'fresh': True, 'refreshModels': True})
                native = next(item for item in snapshot['providers'] if item['instanceId'] == provider)
                if not native.get('installed') or native.get('status') != 'ready':
                    raise RuntimeError('Native T3 provider was not ready: ' + json.dumps(native))
                thread_id = str(uuid.uuid4())
                dispatch('thread.create', threadId=thread_id, projectId=project_id,
                    title='Native ' + harness + ' proof', modelSelection={'instanceId': provider, 'model': model},
                    runtimeMode='full-access', interactionMode='default', branch=None, worktreePath=None,
                    createdBy='user', creationSource='web')
                def turn(phase, text=None):
                    start = len(records)
                    nonce = 'T3_NATIVE_' + phase + '_' + uuid.uuid4().hex
                    invocation = {'codex': '$compound-engineering:ce-noslop ',
                                  'claude': '/compound-engineering:ce-noslop ', 'pi': '/skill:ce-noslop '}[harness]
                    dispatch('message.dispatch', threadId=thread_id, messageId=str(uuid.uuid4()),
                        text=text or (invocation + nonce + ' Reply with the fixture response. Execute no tools.'),
                        attachments=[], dispatchMode={'type': 'start_immediately'}, createdBy='user', creationSource='web',
                        context={'version': 1, 'records': [{'version': 1, 'contextId': 'native_ce', 'label': 'CE no slop',
                            'kind': 'skill', 'name': 'ce-noslop' if harness == 'pi' else 'compound-engineering:ce-noslop'}]})
                    deadline = time.monotonic() + 90
                    projection = None
                    while time.monotonic() < deadline:
                        projection = call('orchestration.getThreadProjection', {'threadId': thread_id})
                        runs = projection.get('runs', [])
                        if runs and all(item.get('status') in ('completed', 'interrupted', 'failed', 'cancelled', 'rolled_back') for item in runs):
                            break
                        time.sleep(.1)
                    if not runs or runs[-1].get('status') != 'completed':
                        raise RuntimeError('Native T3 ' + harness + ' did not complete its fixture turn: '
                                           + json.dumps(runs[-1:] if runs else []))
                    payloads = [body for path, body in records[start:] if path.endswith(('/responses', '/messages', '/chat/completions'))
                                and (nonce in '\n'.join(strings(body)) or text)]
                    if not payloads and text is None:
                        detail = {key: projection.get(key) for key in ('runs', 'attempts', 'runtimeRequests')}
                        raise RuntimeError('T3 native ' + harness + ' turn did not reach transport: ' + json.dumps(detail)[-3500:])
                    if text is None:
                        check_context(payloads[-1], harness, True, existing=True)
                        content = '\n'.join(strings(payloads[-1]))
                        if 'INCORRECT_INHERITED_OVERRIDE' in content:
                            raise RuntimeError('Inherited Codex launch arguments masked managed context.')
                        if 'T3 Code' not in content:
                            raise RuntimeError('Native application context disappeared from T3 ' + harness)
                        if phase == 'fresh' and 'Write without slop' not in content:
                            raise RuntimeError('Native CE invocation disappeared from actual T3 ' + harness)
                    return projection
                def direct():
                    binary = Path(settings['providerInstances'][provider]['config']['binaryPath'])
                    if harness == 'codex':
                        codex_turn(binary, [], env, cwd, root / ('concurrent-' + uuid.uuid4().hex + '.log'),
                                   records, addition=False)
                        return
                    nonce = 'CLI_NATIVE_' + uuid.uuid4().hex
                    start = len(records)
                    command_args = ([str(binary), '--print', '/compound-engineering:ce-noslop ' + nonce,
                        '--tools', '', '--max-turns', '1', '--no-session-persistence'] if harness == 'claude' else
                        [str(binary), '--no-session', '--no-tools', '--print', '/skill:ce-noslop ' + nonce])
                    run(command_args, env, cwd)
                    payloads = [body for path, body in records[start:]
                                if path.endswith(('/messages', '/chat/completions')) and nonce in '\n'.join(strings(body))]
                    if not payloads:
                        raise RuntimeError('Concurrent native CLI did not reach its transport.')
                    check_context(payloads[-1], harness, False)
                with ThreadPoolExecutor(max_workers=1) as pool:
                    concurrent = pool.submit(direct)
                    projection = turn('fresh')
                    concurrent.result()
                dispatch('thread.interaction-mode.set', threadId=thread_id, interactionMode='plan')
                turn('plan')
                dispatch('thread.interaction-mode.set', threadId=thread_id, interactionMode='default')
                projection = turn('mode-change')
                native_threads = {item['nativeThreadRef']['nativeId'] for item in projection.get('providerThreads', [])
                                  if item.get('nativeThreadRef')}
                sessions = projection.get('providerSessions', [])
                if not native_threads or not sessions:
                    raise RuntimeError('Native T3 resume proof requires an established session and native thread.')
                for session in sessions:
                    dispatch('provider-session.detach', threadId=thread_id, providerSessionId=session['id'])
                resumed = turn('resumed')
                resumed_threads = {item['nativeThreadRef']['nativeId'] for item in resumed.get('providerThreads', [])
                                   if item.get('nativeThreadRef')}
                if resumed_threads != native_threads:
                    raise RuntimeError('Native T3 did not resume the same ' + harness + ' conversation.')
                compacted = turn('compact', '/compact')
                if not any(item.get('type') == 'compaction' and item.get('status') == 'completed'
                           for item in compacted.get('turnItems', [])):
                    detail = [item for item in compacted.get('turnItems', []) if item.get('type') in ('compaction', 'error')]
                    raise RuntimeError('Actual T3 did not report completed native ' + harness + ' compaction: ' + json.dumps(detail))
                turn('after-compaction')
                direct()
                print('Actual disposable T3 native ' + harness + ' request/context proof passed')
        except Exception as error:
            log.flush()
            diagnostics = [line for line in (root / 't3-server.log').read_text(encoding='utf-8').splitlines()
                           if 'WARN' in line or 'ERROR' in line or 'Error:' in line]
            raise RuntimeError(str(error) + '\nT3 fixture diagnostics: ' + '\n'.join(diagnostics[-12:])) from error
        finally:
            if rpc:
                rpc.close()
            if job:
                job.terminate()
            elif process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex-package', type=Path)
    parser.add_argument('--claude-binary', type=Path)
    parser.add_argument('--pi-binary', type=Path)
    parser.add_argument('--plugin-directory', type=Path)
    parser.add_argument('--expected-target')
    parser.add_argument('--install-desktop', action='store_true')
    args = parser.parse_args()
    with temporary_destination() as temporary, model_transport() as (endpoint, records):
        root = Path(temporary)
        home, source, outside = root / "user's 한글", root / 'home', root / 'repository'
        for path in (home, source, outside):
            path.mkdir()
        (outside / '.git').mkdir()
        (root / '.chezmoiroot').write_text('home\n')
        for directory in ('.chezmoidata', '.chezmoitemplates', 'private_dot_codex', 'private_dot_claude',
                          'private_dot_pi', 'private_dot_t3'):
            shutil.copytree(REPO / 'home' / directory, source / directory)
        shutil.copy2(REPO / 'home/.chezmoiignore', source)
        declarations = source / '.chezmoidata/personal-apps.json'
        apps = json.loads(declarations.read_text())
        apps['personalApps'] = {name: apps['personalApps'][name] for name in ('codex', 'claude', 'pi')}
        declarations.write_text(json.dumps(apps))
        (source / '.chezmoitemplates/agent-instructions').write_text(
            '{{ if eq (get . "context" | default "baseline") "t3" }}T3_ONLY_6C32\nQuoted "text" and apostrophe\'s.\n'
            '{{ else }}NATIVE_COMMON_71AE\nNATIVE_EXISTING_USER_98D1\n'
            '{{ if eq .harness "codex" }}NATIVE_CODEX_9F26{{ else if eq .harness "claude" }}NATIVE_CLAUDE_9F26'
            '{{ else if eq .harness "pi" }}NATIVE_PI_9F26{{ else }}FOREIGN_HARNESS_B8C1{{ end }}{{ end }}')
        (outside / 'AGENTS.md').write_text('NATIVE_REPOSITORY_41D2\n')
        (outside / 'CLAUDE.md').write_text('NATIVE_REPOSITORY_41D2\n')
        env = {key: value for key, value in os.environ.items() if not any(word in key.upper() for word in
               ('API_KEY', 'TOKEN', 'SECRET', 'CODEX', 'CLAUDE', 'ANTHROPIC', 'OPENAI', 'GROK', 'PI_', 'AWS_', 'PROXY', 'CHEZMOI_'))}
        env.update(HOME=str(home), USERPROFILE=str(home), APPDATA=str(root / 'config'), LOCALAPPDATA=str(root / 'local'),
                   CODEX_HOME=str(home / '.codex'), XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'),
                   PSModuleAnalysisCachePath=str(root / 'module-cache'), ANTHROPIC_API_KEY='inert-fixture-key',
                   ANTHROPIC_AUTH_TOKEN='inert-fixture-token', ANTHROPIC_BASE_URL=endpoint.removesuffix('/v1'),
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1', NO_COLOR='1')
        for name in ('GLOBAL', 'SYSTEM'):
            git_config = root / ('empty-git-' + name.lower())
            git_config.write_text('')
            env['GIT_CONFIG_' + name] = str(git_config)
        assets = []
        if args.codex_package:
            shutil.copytree(args.codex_package, home / '.local', dirs_exist_ok=True)
        else:
            assets.append('codex-package')
        if args.claude_binary:
            (home / '.local/bin').mkdir(parents=True, exist_ok=True)
            shutil.copy2(args.claude_binary, home / '.local/bin' / ('claude.exe' if os.name == 'nt' else 'claude'))
        else:
            assets.append('personal-apps')
        if args.pi_binary:
            shutil.copytree(args.pi_binary.parent, home / '.local/bin/pi-native')
        elif 'personal-apps' not in assets:
            assets.append('personal-apps')
        plugin = home / '.local/share/dotfiles/harness-plugins/compound-engineering'
        if args.plugin_directory:
            plugin.mkdir(parents=True)
            shutil.copy2(args.plugin_directory / 'package.json', plugin / 'package.json')
            for resource in ('skills', '.pi', '.codex-plugin', '.claude-plugin'):
                shutil.copytree(args.plugin_directory / resource, plugin / resource)
            shutil.copytree(args.plugin_directory / '.agents/plugins', plugin / '.agents/plugins')
        else:
            assets.append('harness-plugins')
        copy_asset_templates(source, assets)
        config = root / 'chezmoi.toml'
        config.write_text('')
        chez = [executable('chezmoi'), '--config', str(config), '--source', str(source), '--destination', str(home),
                '--cache', str(root / 'asset-cache'), '--persistent-state', str(root / 'state.boltdb'), '--no-tty']
        target = run([*chez, 'execute-template', '{{ .chezmoi.os }}-{{ .chezmoi.arch }}'], env, outside).strip()
        if args.expected_target and args.expected_target != target:
            raise RuntimeError('Native instruction runner does not match expected target.')
        applied = run_with_assets([*chez, 'apply', '--force', '--exclude=scripts'], env=env,
                                  capture_output=True, text=True, timeout=300)
        applied.check_returncode()
        suffix = '.exe' if os.name == 'nt' else ''
        codex, claude = (home / '.local/bin' / (name + suffix) for name in ('codex', 'claude'))
        pi = home / '.local/bin/pi-native' / ('pi' + suffix)
        codex_config = home / '.codex/config.toml'
        codex_config.write_text('cli_auth_credentials_store = "file"\ndeveloper_instructions = "EXISTING_CODEX_LAUNCH"\n'
            'model = "gpt-5.1-codex"\nmodel_provider = "fixture"\n' + codex_config.read_text()
            + '\n[model_providers.fixture]\nname = "Controlled local fixture"\nbase_url = ' + json.dumps(endpoint)
            + '\nwire_api = "responses"\nrequires_openai_auth = false\nrequest_max_retries = 0\nstream_max_retries = 0\n')
        run([codex, 'plugin', 'marketplace', 'add', plugin], env, outside)
        run([codex, 'plugin', 'add', 'compound-engineering@compound-engineering-plugin'], env, outside)
        run([claude, 'plugin', 'marketplace', 'add', plugin, '--scope', 'user', '--json'], env, outside)
        run([claude, 'plugin', 'install', 'compound-engineering@compound-engineering-plugin', '--scope', 'user', '--json'], env, outside)
        with __import__('unittest.mock', fromlist=['patch']).patch.dict(os.environ, env, clear=True):
            pi_settings.apply(root, home)
        pi_settings.install_credential(home / '.pi/agent', 'inert-native-fixture')
        pi_preferences = home / '.pi/agent/settings.json'
        preferences = json.loads(pi_preferences.read_text())
        # Exercise real manual compaction with short fixture turns instead of
        # relying on the owner's normal 20k-token retention threshold.
        preferences['compaction'] = {'enabled': True, 'keepRecentTokens': 100, 'reserveTokens': 1000}
        pi_preferences.write_text(json.dumps(preferences))
        for filename in ('dotfiles-model-lock.json', 'models.json', 'dotfiles-policy.ts'):
            file = home / '.pi/agent' / filename
            file.write_text(file.read_text().replace('https://api.synthetic.new/openai/v1', endpoint))
        settings_path = home / '.t3/userdata/settings.json'
        settings = json.loads(settings_path.read_text())
        old_claude = root / 'existing-append.md'
        old_claude.write_text('EXISTING_CLAUDE_LAUNCH\n')
        settings['providerInstances']['claudeAgent']['config']['launchArgs'] = instructions.join_args([
            '--append-system-prompt-file', str(old_claude)])
        settings['providerInstances']['pi']['config']['launchArgs'] = '--append-system-prompt EXISTING_PI_LAUNCH'
        settings_path.write_text(json.dumps(settings))
        instructions.apply(home, env)
        settings = json.loads(settings_path.read_text())
        snapshot = {path: path.read_bytes() for path in (codex_config, home / '.codex/AGENTS.md', home / '.claude/CLAUDE.md', home / '.pi/agent/AGENTS.md')}
        codex_args = instructions.tokenize(settings['providerInstances']['codex']['config']['launchArgs'])
        # Complete native SQLite's first initialization before concurrent users
        # open the same home; the two tested instances still share that home.
        codex_turn(codex, [], env, outside, root / 'initial.log', records, addition=False)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(codex_turn, codex, arguments, env, outside, root / name, records, addition=addition)
                       for arguments, name, addition in (([], 'direct.log', False), (codex_args, 't3.log', True))]
            for future in futures:
                future.result()
        codex_turn(codex, [], env, outside, root / 'later.log', records, addition=False)
        for name, binary in (('claude', claude), ('pi', pi)):
            provider = 'claudeAgent' if name == 'claude' else 'pi'
            extra = instructions.tokenize(settings['providerInstances'][provider]['config']['launchArgs'])
            base = ([str(binary), '--print', '/compound-engineering:ce-noslop Reply with the fixture response.',
                     '--tools', '', '--max-turns', '1', '--no-session-persistence'] if name == 'claude' else
                    [str(binary), '--no-session', '--no-tools', '--print', '/skill:ce-noslop Reply with the fixture response.'])
            for addition in (False, True, False):
                start = len(records)
                run([*base, *(extra if addition else [])], env, outside)
                paths = ('/messages',) if name == 'claude' else ('/chat/completions',)
                payloads = [body for path, body in records[start:] if path.endswith(paths) and 'Write without slop' in '\n'.join(strings(body))]
                if not payloads:
                    raise RuntimeError('Native CE invocation disappeared from ' + name)
                check_context(payloads[0], name, addition, existing=addition)
        t3_turns(root, home, outside, env, target, args.install_desktop, records)
        for path, content in snapshot.items():
            if path.read_bytes() != content:
                raise RuntimeError('Per-launch context changed a shared native instruction/config file.')
        print(f'Native {target}: Codex/Claude/Pi direct, T3 launch options, native CE, and later-CLI isolation passed')


if __name__ == '__main__':
    main()
