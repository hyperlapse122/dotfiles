"""Prove native Grok discovery, pinned CE expansion, and T3 ACP startup.

All state belongs to disposable homes. Inference requests go to a rejecting
loopback endpoint; no account login or successful model response is used.
"""

import argparse
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
import tempfile
import threading
import time
from unittest.mock import patch

from asset_fixtures import copy_asset_templates, run_with_assets
from smoke_personal_apps import REPO, check_version, executable
from smoke_codex import strings

sys.path.insert(0, str(REPO / 'scripts'))
spec = importlib.util.spec_from_file_location('grok_plugins', REPO / 'scripts/grok-plugins.py')
grok_plugins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grok_plugins)


@contextmanager
def destination():
    # Grok derives installed-plugin IDs from the full local source path. Keep
    # this fixture short so native skill loading stays below Windows MAX_PATH.
    root = Path(tempfile.mkdtemp(prefix='gk-')).resolve()
    try:
        yield root
    finally:
        if root.parent != Path(tempfile.gettempdir()).resolve() or not root.name.startswith('gk-'):
            raise RuntimeError('Refusing cleanup outside the Grok fixture root.')
        shutil.rmtree('\\\\?\\' + str(root) if os.name == 'nt' else root)


def invoke(binary, arguments, env, cwd, *, success=True):
    result = subprocess.run([str(binary), *arguments], env=env, cwd=cwd, capture_output=True,
                            text=True, encoding='utf-8', errors='replace', timeout=90)
    if success and result.returncode:
        raise RuntimeError('Native Grok command failed: ' + result.stderr[-2000:])
    return result


@contextmanager
def capture_requests():
    requests = []
    class Capture(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({'object': 'list', 'data': [{'id': 'grok-code-fast-1',
                'object': 'model', 'created': 1, 'owned_by': 'xai'}]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0')))))
            body = b'{"error":{"message":"Intentional capture-only rejection","type":"invalid_request_error"}}'
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_args):
            pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Capture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/v1', requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def t3_startup(binary, root, home, outside, env, target, install_desktop):
    from smoke_antigravity import desktop_command
    from smoke_t3_code import T3Rpc, provision_desktop
    real_env = os.environ.copy()
    if install_desktop:
        provision_desktop(target, root, real_env)
    command = desktop_command(Path(real_env.get('USERPROFILE', real_env.get('HOME', ''))), real_env)
    t3_home = home / '.t3'
    settings_path = t3_home / 'userdata/settings.json'
    settings = json.loads(settings_path.read_text())
    provider = settings['providerInstances']['grok']
    if provider['config']['binaryPath'] != binary.as_posix() or provider['driver'] != 'grok':
        raise RuntimeError('T3 must select the absolute native Grok executable.')
    for name, entry in settings['providerInstances'].items():
        if name != 'grok':
            entry['enabled'] = False
            entry.setdefault('config', {})['enabled'] = False
    settings_path.write_text(json.dumps(settings))
    env = dict(env, ELECTRON_RUN_AS_NODE='1', T3CODE_DESKTOP_CLI_LAUNCHER='1', T3CODE_HOME=str(t3_home))
    env['PATH'] = os.pathsep.join(part for part in env.get('PATH', '').split(os.pathsep)
                                if part and '.local/bin' not in part.replace('\\', '/').lower())
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
                    raise RuntimeError('The disposable T3 server exited before Grok discovery.')
                try:
                    rpc = T3Rpc(port, token)
                    break
                except OSError:
                    time.sleep(.1)
            if rpc is None:
                raise RuntimeError('The disposable T3 server did not become ready.')
            refreshed = rpc.call('1', 'server.refreshProviders', {
                'instanceId': 'grok', 'cwd': str(outside), 'fresh': True, 'refreshModels': True})
            snapshot = next((item for item in refreshed.get('providers', []) if item['instanceId'] == 'grok'), None)
            if (snapshot is None or not snapshot.get('installed') or snapshot.get('driver') != 'grok'
                    or snapshot.get('status') != 'ready'
                    or 'goal' not in {entry['name'].lstrip('/') for entry in snapshot.get('slashCommands', [])}):
                raise RuntimeError('Fresh T3 did not initialize the native managed Grok ACP driver.')
            print('Fresh T3 initialized native Grok with the managed binary directory absent from PATH')
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
    parser.add_argument('--binary', type=Path, help='Use an already verified local native artifact')
    parser.add_argument('--plugin-directory', type=Path)
    parser.add_argument('--expected-target')
    parser.add_argument('--t3', action='store_true')
    parser.add_argument('--install-desktop', action='store_true')
    args = parser.parse_args()
    pins = json.loads((REPO / 'home/.chezmoidata/personal-app-lock.json').read_text())['personalAppLocks']
    with destination() as root, capture_requests() as (endpoint, requests):
        source, home, outside = root / 's', root / "u'한", root / 'w'
        for directory in (source, home, outside):
            directory.mkdir()
        for directory in ('.chezmoidata', '.chezmoitemplates', 'private_dot_grok'):
            shutil.copytree(REPO / 'home' / directory, source / directory)
        if args.t3 or args.install_desktop:
            shutil.copytree(REPO / 'home/private_dot_t3', source / 'private_dot_t3')
        shutil.copy2(REPO / 'home/.chezmoiignore', source / '.chezmoiignore')
        apps_path = source / '.chezmoidata/personal-apps.json'
        apps = json.loads(apps_path.read_text())
        apps['personalApps'] = {'grok': apps['personalApps']['grok']}
        apps_path.write_text(json.dumps(apps))
        markers = {'common': 'GROK_COMMON_NATIVE_71AE', 'grok': 'GROK_NATIVE_9F26',
                   'foreign': 'GROK_FOREIGN_B8C1'}
        (source / '.chezmoitemplates/agent-instructions').write_text(markers['common']
            + '\n{{ if eq .harness "grok" }}' + markers['grok']
            + '{{ else }}' + markers['foreign'] + '{{ end }}\n')
        for directory, name in (('.claude', 'CLAUDE.md'), ('.cursor', 'AGENTS.md')):
            (home / directory).mkdir()
            (home / directory / name).write_text(markers['foreign'])
        env = {key: value for key, value in os.environ.items()
               if not any(word in key.upper() for word in ('API_KEY', 'TOKEN', 'SECRET', 'GROK', 'XAI', 'CHEZMOI_', 'PROXY', 'GIT_'))}
        env.update(HOME=str(home), USERPROFILE=str(home), GROK_HOME=str(home / '.grok'),
                   APPDATA=str(root / 'config'), LOCALAPPDATA=str(root / 'local'),
                   XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'),
                   PSModuleAnalysisCachePath=str(root / 'module-cache'), GROK_DISABLE_AUTOUPDATER='1',
                   XAI_API_KEY='inert-grok-fixture', GROK_XAI_API_BASE_URL=endpoint,
                   GROK_MODELS_BASE_URL=endpoint, GROK_MODELS_LIST_URL=endpoint + '/models', NO_COLOR='1')
        (root / 'gitconfig').write_text('')
        env.update(GIT_CONFIG_GLOBAL=str(root / 'gitconfig'), GIT_CONFIG_NOSYSTEM='1')
        binary = home / '.local/bin' / ('grok.exe' if os.name == 'nt' else 'grok')
        plugin = home / '.local/share/dotfiles/harness-plugins/compound-engineering'
        assets = []
        if args.binary:
            binary.parent.mkdir(parents=True)
            shutil.copy2(args.binary, binary)
        else:
            assets.append('personal-apps')
        if args.plugin_directory:
            plugin.mkdir(parents=True)
            for name in ('.grok-plugin', 'skills'):
                shutil.copytree(args.plugin_directory / name, plugin / name)
        else:
            assets.append('harness-plugins')
        copy_asset_templates(source, assets)
        (home / '.grok').mkdir()
        config_path = home / '.grok/config.toml'
        config_path.write_text('[cli]\nshow_tips=false\n[session]\nauto_compact_threshold_percent=73\n')
        state = home / '.grok/unrelated-state'
        state.write_text('preserve unrelated application state')
        config = root / 'chezmoi.toml'
        config.write_text('')
        command = [executable('chezmoi'), '--config', str(config), '--source', str(source),
                   '--destination', str(home), '--cache', str(root / 'chezmoi-cache'),
                   '--persistent-state', str(root / 'state.boltdb')]
        target = subprocess.run([*command, 'execute-template', '{{ .chezmoi.os }}-{{ .chezmoi.arch }}'],
                                env=env, capture_output=True, text=True, check=True).stdout.strip()
        if args.expected_target and target != args.expected_target:
            raise RuntimeError('Native Grok runner does not match the expected target.')
        applied = run_with_assets([*command, 'apply', '--force', '--exclude=scripts'],
                                  env=env, capture_output=True, text=True, timeout=300)
        if applied.returncode:
            raise RuntimeError('Cannot prepare native Grok fixture: ' + applied.stderr[-2000:])
        check_version(invoke(binary, ['--version'], env, outside).stdout, pins['grok']['tag'])
        other = root / 'other'
        (other / '.grok-plugin').mkdir(parents=True)
        (other / '.grok-plugin/plugin.json').write_text(json.dumps({'name': 'smoke-unrelated', 'version': '1.0.0'}))
        invoke(binary, ['plugin', 'install', '--trust', str(other)], env, outside)
        previous_ce = root / 'previous-ce'
        (previous_ce / '.grok-plugin').mkdir(parents=True)
        (previous_ce / '.grok-plugin/plugin.json').write_text(json.dumps({'name': 'compound-engineering', 'version': '0.0.1'}))
        invoke(binary, ['plugin', 'install', '--trust', str(previous_ce)], env, outside)
        with patch.dict(os.environ, env, clear=True):
            grok_plugins.apply(home)
        inspection = json.loads(invoke(binary, ['inspect', '--json'], env, outside).stdout)
        managed = next(item for item in inspection['plugins'] if item['name'] == 'compound-engineering')
        native_skill = Path(managed['path']) / 'skills/ce-noslop/SKILL.md'
        original_skill = (plugin / 'skills/ce-noslop/SKILL.md').read_bytes()
        if native_skill.read_bytes() != original_skill:
            raise RuntimeError('Native Grok installed a different CE skill revision.')
        invoke(binary, ['plugin', 'disable', 'compound-engineering'], env, outside)
        native_skill.write_text('corrupted managed cache')
        if args.plugin_directory:
            # Local characterization supplies the immutable transport fixture;
            # the default path below proves repair through shared preparation.
            (plugin / 'skills/ce-noslop/SKILL.md').write_bytes(original_skill)
        else:
            repaired_assets = run_with_assets([*command, 'apply', '--force', '--exclude=scripts'],
                                             env=env, capture_output=True, text=True, timeout=300)
            repaired_assets.check_returncode()
        with patch.dict(os.environ, env, clear=True):
            grok_plugins.apply(home)
        repaired = json.loads(invoke(binary, ['inspect', '--json'], env, outside).stdout)
        managed = next(item for item in repaired['plugins'] if item['name'] == 'compound-engineering')
        if not managed['enabled'] or native_skill.read_bytes() != original_skill:
            raise RuntimeError('Explicit apply did not repair native Grok CE enablement/cache. '
                               + str({'enabled': managed['enabled'], 'skillRestored': native_skill.read_bytes() == original_skill}))
        if not next(item for item in repaired['plugins'] if item['name'] == 'smoke-unrelated')['enabled']:
            raise RuntimeError('Explicit apply changed unrelated native Grok plugin state.')
        skills = [item for item in repaired['skills'] if item['name'] == 'ce-noslop']
        if len(skills) != 1:
            raise RuntimeError('Native Grok CE skill discovery was missing or duplicated.')
        if state.read_text() != 'preserve unrelated application state' or 'auto_compact_threshold_percent = 73' not in config_path.read_text():
            raise RuntimeError('Explicit apply changed unrelated native Grok settings/state.')
        result = invoke(binary, ['-m', 'grok-code-fast-1', '--max-turns', '1', '-p',
                                 '/ce-noslop Rewrite the word hello.'], env, outside, success=False)
        body = original_skill.decode('utf-8').split('---', 2)[-1].strip().replace('\r\n', '\n')
        if result.returncode == 0 or not requests:
            raise RuntimeError('Native Grok did not reach the rejecting inference endpoint.')
        # Native Grok also sends small auxiliary requests with another model.
        # The explicitly selected agent model carries the instruction context.
        agent_requests = [request for request in requests if request.get('model') == 'grok-code-fast-1']
        if not agent_requests:
            raise RuntimeError('Native Grok did not request the selected agent model.')
        for request in agent_requests:
            if not any(body in text.replace('\r\n', '\n') for text in strings(request)):
                raise RuntimeError('Native Grok did not expand the full CE skill into its agent request.')
            payload = json.dumps(request)
            for marker in ('common', 'grok'):
                if payload.count(markers[marker]) != 1:
                    raise RuntimeError('Native Grok instructions are missing or duplicated: ' + marker)
        if markers['foreign'] in json.dumps(requests):
            raise RuntimeError('Native Grok loaded foreign harness instructions.')
        if args.t3 or args.install_desktop:
            t3_startup(binary, root, home, outside, env, target, args.install_desktop)
        print(f'Native Grok {pins["grok"]["tag"]}: {target}, private settings, native CE repair/discovery/expansion passed')
        print('Model completion was not exercised: loopback inference requests were deliberately rejected.')


if __name__ == '__main__':
    main()
