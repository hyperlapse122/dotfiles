"""Verify official registry helpers on disposable hosted native credential stores."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

from smoke_github_auth import failure_summary, native_keychain
from asset_fixtures import copy_asset_templates, run_with_assets

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
SPEC = importlib.util.spec_from_file_location('container_auth', REPO / 'scripts/container-auth.py')


@contextmanager
def ping_only_connection():
    # Remote Podman initializes a connection even for host-side --get-login.
    # Answer only that handshake; the account must come from the real native
    # credential helper, never from this fixture or an engine/registry service.
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if not self.path.endswith('/_ping'):
                self.send_error(501)
                return
            self.send_response(200)
            self.send_header('Libpod-API-Version', '6.1.4')
            self.send_header('API-Version', '1.41')
            self.end_headers()
            self.wfile.write(b'OK')

        do_HEAD = do_GET

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield 'tcp://127.0.0.1:' + str(server.server_port)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-podman', action='store_true', help='Require real host-side Podman credential lookup')
    args = parser.parse_args()
    if not (os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'):
        raise SystemExit('Native registry credential writes require a disposable GitHub-hosted runner')
    chezmoi = shutil.which('chezmoi')
    if not chezmoi:
        raise SystemExit('Native registry smoke requires chezmoi')
    auth = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(auth)
    platform = 'windows' if os.name == 'nt' else ('darwin' if sys.platform == 'darwin' else 'linux')
    suffix = auth.helper_suffix(platform)
    name = 'docker-credential-' + suffix
    with tempfile.TemporaryDirectory(prefix='registry-native-', dir=os.environ['RUNNER_TEMP']) as temporary:
        root = Path(temporary)
        source, home = root / 'source', root / 'home'
        source.mkdir()
        (source / '.chezmoidata').mkdir()
        for filename in ('personal-apps.json', 'personal-app-lock.json'):
            shutil.copy2(REPO / 'home/.chezmoidata' / filename, source / '.chezmoidata' / filename)
        apps_path = source / '.chezmoidata/personal-apps.json'
        apps = json.loads(apps_path.read_text())
        apps['personalApps'] = {name: apps['personalApps'][name]}
        apps_path.write_text(json.dumps(apps))
        copy_asset_templates(source, ('personal-apps',))
        config = root / 'chezmoi.toml'
        config.write_text('')
        env = os.environ.copy()
        env.update({'HOME': str(home), 'USERPROFILE': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
                    'PSModuleAnalysisCachePath': str(root / 'module-analysis-cache'),
                    'DOCKER_CONFIG': str(home / '.docker'), 'REGISTRY_AUTH_FILE': str(home / '.config/containers/auth.json')})
        if sys.platform == 'darwin':
            env['HOME'] = os.environ['HOME']
        command = [chezmoi, '--source', str(source), '--destination', str(home), '--config', str(config),
                   '--cache', str(root / 'cache'), '--persistent-state', str(root / 'state'),
                   'apply', '--force', '--exclude=scripts']
        installed = run_with_assets(command, env=env, capture_output=True, timeout=300)
        if installed.returncode:
            raise auth.common.AuthError('Cannot install the pinned native registry helper.')
        helper = home / '.local/bin' / (name + ('.exe' if os.name == 'nt' else ''))
        env['PATH'] = str(helper.parent) + os.pathsep + env.get('PATH', '')
        registry = 'dotfiles-fixture-' + uuid.uuid4().hex + '.invalid'
        records = [{'registry': registry, 'user': 'fixture-user', 'token': 'synthetic-native-registry-fixture'}]
        paths = auth.configuration_paths(home, env, platform=platform)
        with native_keychain(root, env):
            try:
                auth.reconcile(records, paths, [str(helper)], suffix, env)
                if auth.helper_get([str(helper)], registry, env) != {'Username': records[0]['user'], 'Secret': records[0]['token']}:
                    raise RuntimeError('Native registry readback failed')
                for path in paths:
                    document = json.loads(path.read_text())
                    if document['credHelpers'][registry] != suffix or document.get('auths'):
                        raise RuntimeError('Native registry configuration did not use a helper')
                podman = None
                for command_name in ('podman-remote', 'podman'):
                    candidate = shutil.which(command_name, path=env.get('PATH'))
                    if candidate:
                        try:
                            version = auth.common.run_private([candidate, '--version'], env=env,
                                operation='Cannot identify the native Podman fixture.').strip()
                            if version == 'podman version 6.1.4':
                                podman = candidate
                                break
                        except auth.common.AuthError:
                            continue
                if args.require_podman and not podman:
                    raise RuntimeError('Native Podman client fixture is required')
                if podman:
                    with ping_only_connection() as connection:
                        env['CONTAINER_HOST'] = connection
                        account = auth.common.run_private([podman, 'login', '--get-login', '--authfile', env['REGISTRY_AUTH_FILE'], registry],
                            env=env, operation='Native host-side Podman credential lookup failed.').strip()
                    if account != records[0]['user']:
                        raise RuntimeError('Native Podman selected the wrong registry account')
                    print('Native host-side Podman lookup verified without an engine or registry request.')
                else:
                    print('Podman CLI lookup not exercised: no native client fixture was supplied.')
                print('Official native registry helper store/readback and Docker/Podman config verified.')
            finally:
                auth.common.run_private([str(helper), 'erase'], input=registry, env=env,
                                        operation='Cannot clean up the synthetic registry credential.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(failure_summary(error, ('smoke_container_auth.py', 'container-auth.py'))) from None
