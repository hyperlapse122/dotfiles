"""Exercise the pinned native Pi distribution, policy, CE package, and RPC boundary.

Only disposable homes and inert credentials are used. A loopback capture rejects
model requests; this proves request expansion, not authenticated model execution.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import queue
import signal
import shutil
import socket
import subprocess
import sys
import threading
import time
from unittest.mock import patch

from asset_fixtures import copy_asset_templates, run_with_assets
from smoke_personal_apps import REPO, check_version, executable, temporary_destination

sys.path.insert(0, str(REPO / 'scripts'))
spec = importlib.util.spec_from_file_location('pi_settings', REPO / 'scripts/pi-settings.py')
pi_settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pi_settings)


def invoke(binary, arguments, env, cwd, *, success=True):
    result = subprocess.run([str(binary), *arguments], env=env, cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=90)
    if success and result.returncode:
        raise RuntimeError('Native Pi command failed: ' + result.stderr[-2000:])
    return result


class Rpc:
    def __init__(self, binary, env, cwd):
        self.process = subprocess.Popen([str(binary), '--mode', 'rpc', '--no-session'], env=env, cwd=cwd,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, encoding='utf-8')
        self.records = queue.Queue()
        self.errors = []

        def read():
            for line in self.process.stdout:
                try:
                    self.records.put(json.loads(line))
                except ValueError:
                    self.errors.append(line)
            self.records.put(None)

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.number = 0

    def command(self, kind, **fields):
        self.number += 1
        identifier = str(self.number)
        self.process.stdin.write(json.dumps({'id': identifier, 'type': kind, **fields}) + '\n')
        self.process.stdin.flush()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                event = self.records.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if event is None:
                raise RuntimeError('Pi RPC exited during native policy verification.')
            if event.get('id') == identifier and event.get('type') == 'response':
                return event
        raise RuntimeError('Timed out waiting for native Pi RPC.')

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()


def t3_startup(binary, root, home, outside, env, target, install_desktop):
    from smoke_antigravity import desktop_command
    from smoke_t3_code import T3Rpc, provision_desktop
    real_env = os.environ.copy()
    if install_desktop:
        provision_desktop(target, root, real_env)
    command = desktop_command(Path(real_env.get('USERPROFILE', real_env.get('HOME', ''))), real_env)
    t3_home = home / '.t3'
    settings_path = t3_home / 'userdata/settings.json'
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings = json.loads(settings_path.read_text())
    provider = settings['providerInstances']['pi']
    if provider['config']['binaryPath'] != binary.as_posix() or provider['driver'] != 'pi':
        raise RuntimeError('T3 does not select the absolute managed native Pi executable.')
    for name, entry in settings['providerInstances'].items():
        if name != 'pi':
            entry['enabled'] = False
            entry.setdefault('config', {})['enabled'] = False
    settings_path.write_text(json.dumps(settings))
    env = {**env, 'ELECTRON_RUN_AS_NODE': '1', 'T3CODE_DESKTOP_CLI_LAUNCHER': '1', 'T3CODE_HOME': str(t3_home)}
    env['PATH'] = os.pathsep.join(part for part in env.get('PATH', '').split(os.pathsep)
                                if part and '.local/bin' not in part.replace('\\', '/').lower()
                                and '.local/bin/pi-native' not in part.replace('\\', '/').lower())
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    token = subprocess.run(command + ['auth', 'session', 'issue', '--base-dir', str(t3_home),
                                     '--scope', 'providers:manage', '--scope', 'orchestration:read',
                                     '--ttl', '5m', '--token-only'], env=env, cwd=outside,
                           capture_output=True, text=True, check=True, timeout=60).stdout.strip()
    with (root / 't3.log').open('w', encoding='utf-8') as log:
        process = subprocess.Popen(command + ['serve', '--mode', 'desktop', '--host', '127.0.0.1',
                                              '--port', str(port), '--base-dir', str(t3_home), '--no-browser'],
                                   env=env, cwd=outside, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=os.name != 'nt')
        rpc = None
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('The disposable T3 server exited before Pi discovery.')
                try:
                    rpc = T3Rpc(port, token)
                    break
                except OSError:
                    time.sleep(.1)
            if rpc is None:
                raise RuntimeError('The disposable T3 server did not become ready.')
            refreshed = rpc.call('1', 'server.refreshProviders', {
                'instanceId': 'pi', 'cwd': str(outside), 'fresh': True, 'refreshModels': True})
            snapshot = next((item for item in refreshed.get('providers', []) if item['instanceId'] == 'pi'), None)
            if (snapshot is None or not snapshot.get('installed') or snapshot.get('status') != 'ready'
                    or snapshot.get('auth', {}).get('status') != 'authenticated'):
                raise RuntimeError('Fresh T3 did not initialize the native managed Pi driver.')
            expected = {'synthetic/' + model['id'] for model in json.loads(
                (home / '.pi/agent/dotfiles-model-lock.json').read_text())['syntheticModelLocks']['models']}
            # T3 adds an alias for Pi's active managed default; it is not a provider.
            expected.add('default')
            actual = {model.get('slug') for model in snapshot.get('models', [])}
            if actual != expected:
                raise RuntimeError('Fresh T3 did not discover exactly the locked native Pi catalog: '
                                   + json.dumps({'expected': sorted(expected), 'actual': sorted(actual, key=str),
                                                 'modelFields': sorted(snapshot.get('models', [{}])[0])}))
            print('Fresh T3 initialized native Pi with the managed binary directories absent from PATH')
        finally:
            if rpc:
                rpc.close()
            if os.name == 'nt':
                subprocess.run([real_env['SYSTEMROOT'] + '/System32/taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                               capture_output=True, timeout=30)
            else:
                os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, help='Use an already verified distribution for local characterization')
    parser.add_argument('--plugin-directory', type=Path)
    parser.add_argument('--expected-target')
    parser.add_argument('--t3', action='store_true', help='Verify startup through an installed T3 desktop server')
    parser.add_argument('--install-desktop', action='store_true', help='Provision T3 on disposable hosted CI only')
    args = parser.parse_args()
    locks = json.loads((REPO / 'home/.chezmoidata/personal-app-lock.json').read_text())
    model_lock = json.loads((REPO / 'home/.chezmoidata/synthetic-model-lock.json').read_text())
    expected_ids = {model['id'] for model in model_lock['syntheticModelLocks']['models']}
    with temporary_destination() as temporary:
        root = Path(temporary)
        source, home, outside = root / 'home', root / "user's 한글 home", root / 'outside'
        for directory in (source, home, outside):
            directory.mkdir()
        (root / '.chezmoiroot').write_text('home\n')
        for directory in ('.chezmoidata', '.chezmoitemplates', 'private_dot_pi'):
            shutil.copytree(REPO / 'home' / directory, source / directory)
        if args.t3 or args.install_desktop:
            shutil.copytree(REPO / 'home/private_dot_t3', source / 'private_dot_t3')
        launchers = source / 'dot_local/bin'
        launchers.mkdir(parents=True)
        for name in ('executable_pi.tmpl', 'executable_pi.ps1.tmpl'):
            shutil.copy2(REPO / 'home/dot_local/bin' / name, launchers / name)
        shutil.copy2(REPO / 'home/.chezmoiignore', source / '.chezmoiignore')
        apps_path = source / '.chezmoidata/personal-apps.json'
        apps = json.loads(apps_path.read_text())
        apps['personalApps'] = {'pi': apps['personalApps']['pi']}
        apps_path.write_text(json.dumps(apps))
        markers = {'common': 'COMMON_PI_NATIVE_71AE', 'pi': 'PI_NATIVE_9F26', 'foreign': 'FOREIGN_PI_B8C1'}
        (source / '.chezmoitemplates/agent-instructions').write_text(
            markers['common'] + '\n{{ if eq .harness "pi" }}' + markers['pi']
            + '{{ else }}' + markers['foreign'] + '{{ end }}\n')
        env = {key: value for key, value in os.environ.items()
               if not any(token in key.upper() for token in ('API_KEY', 'TOKEN', 'PI_', 'CHEZMOI_', 'PROXY'))}
        env.update(HOME=str(home), USERPROFILE=str(home), APPDATA=str(root / 'config'),
                   LOCALAPPDATA=str(root / 'local'),
                   PSModuleAnalysisCachePath=str(root / 'module-analysis-cache'),
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'))
        distribution = home / '.local/bin/pi-native'
        plugin = home / '.local/share/dotfiles/harness-plugins/compound-engineering'
        assets = []
        if args.binary:
            shutil.copytree(args.binary.resolve().parent, distribution)
        else:
            assets.append('personal-apps')
        if args.plugin_directory:
            plugin.mkdir(parents=True)
            shutil.copy2(args.plugin_directory / 'package.json', plugin)
            for resource in ('.pi', 'skills'):
                shutil.copytree(args.plugin_directory / resource, plugin / resource)
        else:
            assets.append('harness-plugins')
        copy_asset_templates(source, assets)
        config = root / 'chezmoi.toml'
        config.write_text('')
        chezmoi = executable('chezmoi')
        command = [chezmoi, '--config', str(config), '--source', str(source), '--destination', str(home),
                   '--cache', str(root / 'chezmoi-cache'), '--persistent-state', str(root / 'state.boltdb')]
        target = subprocess.run([*command, 'execute-template', '{{ .chezmoi.os }}-{{ .chezmoi.arch }}'],
                                env=env, capture_output=True, text=True, check=True).stdout.strip()
        if args.expected_target and target != args.expected_target:
            raise RuntimeError('Native Pi runner target differs from the expected target.')
        apply_command = [*command, 'apply', '--force', '--exclude=scripts']
        prepared = run_with_assets(apply_command, env=env, capture_output=True, text=True, timeout=300)
        if prepared.returncode:
            raise RuntimeError('Cannot prepare the native Pi fixture: ' + prepared.stderr[-3000:])
        if not args.binary:
            resource = distribution / 'package.json'
            original_resource = resource.read_bytes()
            resource.unlink()
            repaired = run_with_assets(apply_command, env=env, capture_output=True, text=True, timeout=300)
            repaired.check_returncode()
            if resource.read_bytes() != original_resource:
                raise RuntimeError('Shared preparation did not repair the native Pi distribution from cache.')
        binary = distribution / ('pi.exe' if os.name == 'nt' else 'pi')
        launcher = home / '.local/bin' / ('pi.ps1' if os.name == 'nt' else 'pi')
        launch_command = ([executable('powershell.exe'), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(launcher)]
                          if os.name == 'nt' else [str(launcher)])
        launched_version = subprocess.run([*launch_command, '--version'], env=env, cwd=outside,
                                          capture_output=True, text=True, encoding='utf-8', timeout=60)
        if launched_version.returncode:
            raise RuntimeError('Managed Pi launcher failed in the disposable Unicode home: ' + launched_version.stderr[-2000:])
        check_version(launched_version.stdout, locks['personalAppLocks']['pi']['tag'])
        check_version(invoke(binary, ['--version'], env, outside).stdout, locks['personalAppLocks']['pi']['tag'])
        with patch.dict(os.environ, env, clear=True):
            pi_settings.apply(root, home)
        agent = home / '.pi/agent'
        settings = json.loads((agent / 'settings.json').read_text())
        settings['retry'] = {'enabled': False}
        settings['packages'] = [{'source': str(plugin), 'extensions': [], 'skills': []}]
        settings['packages'].append({'source': str(root / 'benign-package')})
        benign = root / 'benign-package'
        benign.mkdir()
        (benign / 'package.json').write_text(json.dumps({'name': 'fixture', 'pi': {'extensions': ['./index.ts']}}))
        (benign / 'index.ts').write_text('''export default function(pi) {
          const foreign = {baseUrl:"http://127.0.0.1:9/v1",api:"openai-completions",apiKey:"fixture",
            models:[{id:"foreign-model",name:"Foreign",reasoning:false,input:["text"],
              cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:8192,maxTokens:512}]};
          pi.registerProvider("benign-foreign", foreign);
          pi.on("session_start", () => pi.registerProvider("session-foreign", foreign));
          pi.registerCommand("dotfiles-reload-proof", {description:"reload fixture",handler:async(_,ctx)=>{await ctx.reload();}});
          pi.registerCommand("dotfiles-catalog-proof", {description:"catalog fixture",handler:async(_,ctx)=>{
            console.log("CATALOG="+JSON.stringify(ctx.modelRegistry.getAll().map(m=>[m.provider,m.id])));ctx.shutdown();}});
        }''')
        (agent / 'settings.json').write_text(json.dumps(settings))
        foreign_config = {'baseUrl': 'http://127.0.0.1:9/v1', 'api': 'openai-completions',
                          'apiKey': 'fixture', 'models': [{**model_lock['syntheticModelLocks']['models'][0], 'id': 'foreign-model'}]}
        models = json.loads((agent / 'models.json').read_text())
        models['providers']['custom-foreign'] = foreign_config
        (agent / 'models.json').write_text(json.dumps(models))
        (agent / 'auth.json').write_text(json.dumps({'synthetic': {'type': 'api_key', 'key': 'fixture'},
                                                   'openai': {'type': 'api_key', 'key': 'fixture'}}))
        env['ANTHROPIC_API_KEY'] = 'fixture'
        env['OPENAI_API_KEY'] = 'fixture'
        with patch.dict(os.environ, env, clear=True):
            pi_settings.apply(root, home)
        # Native package registration and a second reconciliation preserve unrelated resources.
        settings = json.loads((agent / 'settings.json').read_text())
        if not any(isinstance(entry, dict) and entry.get('source') == str(benign) for entry in settings['packages']):
            raise RuntimeError('Pi reconciliation removed an unrelated package.')
        catalog = invoke(binary, ['--no-session', '--print', '/dotfiles-catalog-proof'], env, outside)
        encoded = next((line.removeprefix('CATALOG=') for line in catalog.stdout.splitlines() if line.startswith('CATALOG=')), None)
        if encoded is None or {tuple(pair) for pair in json.loads(encoded)} != {('synthetic', identifier) for identifier in expected_ids}:
            raise RuntimeError('Native effective Pi catalog differs from the committed lock.')
        rpc = Rpc(binary, env, outside)
        try:
            def check_catalog():
                response = rpc.command('get_available_models')
                models = response['data']['models']
                if not response['success'] or {(model['provider'], model['id']) for model in models} != {('synthetic', identifier) for identifier in expected_ids}:
                    raise RuntimeError('Pi RPC exposes a model outside the committed lock.')
            check_catalog()
            for provider, identifier in [('openai', 'gpt-4o'), ('custom-foreign', 'foreign-model'), ('benign-foreign', 'foreign-model'), ('session-foreign', 'foreign-model')]:
                if rpc.command('set_model', provider=provider, modelId=identifier)['success']:
                    raise RuntimeError('Pi RPC selected a foreign provider.')
            commands = rpc.command('get_commands')['data']['commands']
            names = [entry['name'] for entry in commands]
            if names.count('skill:ce-noslop') != 1:
                raise RuntimeError('Native CE skill discovery is missing or duplicated: ' + repr([name for name in names if 'noslop' in name]))
            response = rpc.command('prompt', message='/dotfiles-reload-proof')
            if not response['success']:
                raise RuntimeError('Native Pi reload failed.')
            check_catalog()
        finally:
            rpc.close()
        for provider, model in [('openai', 'gpt-4o'), ('custom-foreign', 'foreign-model')]:
            result = invoke(binary, ['--no-session', '--print', '--provider', provider, '--model', model, 'fixture'], env, outside, success=False)
            if result.returncode == 0:
                raise RuntimeError('Explicit foreign Pi model selection succeeded.')
        for provider, model in [('openai', 'gpt-4o'), ('synthetic', 'removed-locked-model')]:
            session = root / 'saved-selection.jsonl'
            timestamp = '2026-01-01T00:00:00.000Z'
            entries = [
                {'type': 'session', 'version': 3, 'id': 'fixture', 'timestamp': timestamp, 'cwd': str(outside)},
                {'type': 'model_change', 'id': '12345678', 'parentId': None, 'timestamp': timestamp,
                 'provider': provider, 'modelId': model},
                {'type': 'message', 'id': '12345679', 'parentId': '12345678', 'timestamp': timestamp,
                 'message': {'role': 'user', 'content': 'Previous harmless fixture message', 'timestamp': 1767225600000}},
            ]
            session.write_text(''.join(json.dumps(entry) + '\n' for entry in entries))
            result = invoke(binary, ['--session', str(session), '--print', '/dotfiles-catalog-proof'], env, outside, success=False)
            if result.returncode == 0 or 'saved model is unavailable' not in result.stderr:
                raise RuntimeError('Pi silently restored an unavailable model selection.')
        if args.t3 or args.install_desktop:
            t3_startup(binary, root, home, outside, env, target, args.install_desktop)
        requests = []
        class Capture(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                requests.append(json.loads(body))
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"capture-only fixture"}}')
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Capture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            endpoint = f'http://127.0.0.1:{server.server_port}/v1'
            # Substitute only the transport dependency in this disposable copy.
            for filename in ('dotfiles-model-lock.json', 'models.json', 'dotfiles-policy.ts'):
                path = agent / filename
                path.write_text(path.read_text().replace('https://api.synthetic.new/openai/v1', endpoint))
            result = invoke(binary, ['--no-session', '--print', '/skill:ce-noslop Rewrite the word hello.'], env, outside, success=False)
            if not requests:
                raise RuntimeError('Pi did not send the native CE invocation to the capture endpoint: ' + result.stderr[-1500:])
            payload = json.dumps(requests[0])
            if markers['common'] not in payload or markers['pi'] not in payload or markers['foreign'] in payload:
                raise RuntimeError('Pi native instructions selected the wrong harness branch.')
            if 'ce-noslop' not in payload or 'Write without slop' not in payload:
                raise RuntimeError('Pi did not expand the native CE skill.')
            if len(requests) != 1:
                raise RuntimeError('Pi retried or fell back after the rejected Synthetic request.')
            (agent / 'auth.json').write_text('{}')
            for key in ('SYNTHETIC_API_KEY', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY'):
                env.pop(key, None)
            invoke(binary, ['--no-session', '--print', 'fixture'], env, outside, success=False)
            if len(requests) != 1:
                raise RuntimeError('Pi contacted a provider with missing Synthetic credentials.')
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        # Native normal invocation must reject a missing policy or lock before a request.
        for filename in ('dotfiles-policy.ts', 'dotfiles-model-lock.json'):
            path = agent / filename
            saved = path.read_bytes()
            path.unlink()
            try:
                if invoke(binary, ['--no-session', '--print', 'fixture'], env, outside, success=False).returncode == 0:
                    raise RuntimeError('Pi accepted missing managed policy files.')
                gate = subprocess.run([*launch_command, '--list-models'], env=env, cwd=outside,
                                      capture_output=True, text=True, timeout=30)
                if gate.returncode == 0:
                    raise RuntimeError('The managed Pi launcher accepted missing policy discovery files.')
            finally:
                path.write_bytes(saved)
        print(f'Native Pi {locks["personalAppLocks"]["pi"]["tag"]}: {target}, locked catalog, foreign blocks, reload, CE expansion, and RPC passed')


if __name__ == '__main__':
    main()
