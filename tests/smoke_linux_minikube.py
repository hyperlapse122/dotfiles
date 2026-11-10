"""Explicit Fedora KDE rootless Podman build/run and minikube HTTP proof.

Run after explicit Linux application and `mise run linux-kubernetes`.
No installation or persistent runtime setup is performed. Podman storage, run
state and network definitions are private to the proof. Exit codes: 0 passed,
1 proof failed/interrupted, 2 host/prerequisites unavailable, 3 cleanup incomplete.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
try:
    import pwd
except ImportError:
    pwd = None
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


REPO = Path(__file__).resolve().parents[1]
# Supported by minikube v1.39.0 constants; matches kubectl v1.37.2's minor.
KUBERNETES_VERSION = 'v1.37.0'
REQUIRED_CONTROLLERS = ('cpu', 'memory', 'pids')
OPTIONAL_CONTROLLERS = ('cpuset', 'io')


def command(args, env, timeout=120):
    result = subprocess.run([str(arg) for arg in args], env=env, capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args!r}: {result.stderr.strip()} (exit {result.returncode})')
    return result.stdout.strip()


def preflight():
    spec = importlib.util.spec_from_file_location('linux_platform', REPO / 'scripts/linux-platform.py')
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    host = probe.inspect_host()
    if not host['supported']:
        raise RuntimeError('; '.join(host['blockers']))
    uid = os.getuid()
    runtime = Path(f'/run/user/{uid}')
    if uid == 0 or not runtime.is_dir() or runtime.is_symlink() or runtime.stat().st_uid != uid:
        raise RuntimeError('Requires a non-root systemd user session with an owned /run/user/$UID.')
    if runtime.stat().st_mode & 0o077:
        raise RuntimeError('The user runtime directory must be private (mode 0700).')
    if not Path('/sys/fs/cgroup/cgroup.controllers').is_file():
        raise RuntimeError('Requires cgroup v2.')
    user = pwd.getpwuid(uid).pw_name
    for name in ('subuid', 'subgid'):
        entries = Path('/etc', name).read_text().splitlines()
        if not any(len(parts := line.split(':')) == 3 and parts[0] in (user, str(uid))
                   and int(parts[2]) >= 65536 for line in entries):
            raise RuntimeError(f'Requires at least 65536 subordinate IDs in /etc/{name}.')
    delegated = Path(f'/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service/cgroup.controllers'
                     ).read_text().split()
    missing = [name for name in REQUIRED_CONTROLLERS if name not in delegated]
    if missing:
        raise RuntimeError('Rootless Podman needs the cpu, memory and pids cgroup controllers delegated to the '
                           f'systemd user session; not delegated: {", ".join(missing)}.')
    optional = [name for name in OPTIONAL_CONTROLLERS if name not in delegated]
    warnings = [f'The systemd user session does not delegate these cgroup controllers: {", ".join(optional)}. '
                'Workloads that set their limits may not start.'] if optional else []
    env = os.environ.copy()
    env['PATH'] = str(Path.home() / '.local/share/dotfiles/build/bin') + os.pathsep + env.get('PATH', '')
    for tool in ('podman', 'minikube', 'kubectl', 'systemctl'):
        if not shutil.which(tool, path=env['PATH']):
            raise RuntimeError(f'Missing prerequisite: {tool}')
    env['XDG_RUNTIME_DIR'] = str(runtime)
    env['DBUS_SESSION_BUS_ADDRESS'] = f'unix:path={runtime}/bus'
    command(['systemctl', '--user', 'show-environment'], env, 15)
    versions = {'minikube': command(['minikube', 'version', '--short'], env, 15),
                'kubectl': json.loads(command(['kubectl', 'version', '--client', '-o', 'json'], env, 15))}
    if versions['minikube'] != 'v1.39.0' or versions['kubectl']['clientVersion']['gitVersion'] != 'v1.37.2':
        raise RuntimeError('Requires provisioned minikube v1.39.0 and kubectl v1.37.2.')
    return runtime, env, {'host': host, 'versions': versions, 'server_requested': KUBERNETES_VERSION,
                          'delegated_controllers': delegated, 'warnings': warnings}


class Proof:
    def __init__(self, runtime, env, report, state_parent=None):
        self.state = Path(tempfile.mkdtemp(prefix='.dotfiles-k8s-', dir=state_parent or Path.home()))
        try:
            self.runtime = Path(tempfile.mkdtemp(prefix='dotfiles-k8s-', dir=runtime))
        except OSError:
            self.state.rmdir()
            raise
        self.name = 'dotfiles-k8s-' + uuid.uuid4().hex[:12]
        self.graphroot = self.state / 'storage'
        storage_conf = self.state / 'storage.conf'
        containers_conf = self.state / 'containers.conf'
        # json.dumps yields a valid TOML basic string for a filesystem path.
        storage_conf.write_text('[storage]\ndriver = "overlay"\n'
                                f'graphroot = {json.dumps(str(self.graphroot))}\n'
                                f'runroot = {json.dumps(str(self.runtime / "storage"))}\n')
        containers_conf.write_text(f'[network]\nnetwork_config_dir = {json.dumps(str(self.state / "networks"))}\n')
        self.env = {key: value for key, value in env.items()
                    if key not in ('DOCKER_HOST', 'CONTAINER_HOST') and not key.startswith('MINIKUBE_')}
        self.env.update(CONTAINERS_STORAGE_CONF=str(storage_conf), CONTAINERS_CONF=str(containers_conf),
                        XDG_RUNTIME_DIR=str(runtime), MINIKUBE_HOME=str(self.state / 'minikube'),
                        KUBECONFIG=str(self.state / 'kubeconfig'))
        self.report = report
        self.report.update(profile=self.name, state=str(self.state), runtime_state=str(self.runtime),
                           storage_conf=str(storage_conf), containers_conf=str(containers_conf),
                           graphroot=str(self.graphroot), ownership='exclusive newly created rootless Podman store',
                           disk_free_before=shutil.disk_usage(self.state.parent).free, commands=[])
        self.started = self.profile = False
        self.forward = None
        self.log = None

    def cmd(self, args, timeout=120):
        self.report['commands'].append([str(arg) for arg in args])
        return command(args, self.env, timeout)

    def wait(self, action, seconds=60):
        deadline = time.monotonic() + seconds
        while True:
            try:
                return action()
            except (RuntimeError, OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.5)

    def http(self, port):
        if self.forward.poll() is not None:
            raise RuntimeError('Port-forward exited before the HTTP proof.')
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(
                f'http://127.0.0.1:{port}/', timeout=3) as response:
            body = response.read(128).decode().strip()
        if body != 'dotfiles-kubernetes-ok':
            raise RuntimeError(f'Unexpected HTTP response: {body!r}')
        return body

    def execute(self):
        self.started = True  # Any Podman command may create the private store.
        info = json.loads(self.cmd(['podman', 'info', '--format', 'json'], 60))
        if (not info['host']['security']['rootless'] or info['host']['cgroupVersion'] != 'v2'
                or Path(info['store']['graphRoot']) != self.graphroot):
            raise RuntimeError('Podman does not report rootless mode, cgroup v2 and the private storage root.')
        self.report['podman'] = info
        context = self.state / 'context'
        context.mkdir()
        (context / 'index.html').write_text('dotfiles-kubernetes-ok\n')
        (context / 'Containerfile').write_text('FROM docker.io/library/busybox:1.37.0\nCOPY index.html /www/index.html\nEXPOSE 8080\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n')
        # Podman stores a locally built image under the localhost registry name.
        image = 'localhost/' + self.name + ':proof'
        self.cmd(['podman', 'build', '-t', image, context], 600)
        body = self.cmd(['podman', 'run', '--rm', image, 'cat', '/www/index.html'])
        if body != 'dotfiles-kubernetes-ok':
            raise RuntimeError('Built image failed the container execution proof.')
        self.profile = True
        self.cmd(['minikube', 'start', '-p', self.name, '--driver=podman', '--rootless',
                  '--container-runtime=containerd', '--kubernetes-version=' + KUBERNETES_VERSION,
                  '--delete-on-failure=false', '--wait=all', '--wait-timeout=5m'], 900)
        self.cmd(['kubectl', 'wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s'], 200)
        self.report['server'] = json.loads(self.cmd(['kubectl', 'version', '-o', 'json']))
        if self.report['server']['serverVersion']['gitVersion'] != KUBERNETES_VERSION:
            raise RuntimeError('Unexpected Kubernetes server version.')
        # minikube cannot read Podman storage, so the image travels as an archive.
        archive = self.state / 'image.tar'
        self.cmd(['podman', 'save', '-o', archive, image], 300)
        self.cmd(['minikube', '-p', self.name, 'image', 'load', archive], 300)
        self.cmd(['kubectl', 'create', 'deployment', self.name, '--image=' + image])
        self.cmd(['kubectl', 'rollout', 'status', 'deployment/' + self.name, '--timeout=180s'], 200)
        # The high port is loopback-only; a collision fails the proof without touching its owner.
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        if port < 1024:
            raise RuntimeError('Expected a high loopback port.')
        self.log = (self.state / 'port-forward.log').open('w')
        self.forward = subprocess.Popen(['kubectl', 'port-forward', 'deployment/' + self.name,
                                         f'{port}:8080', '--address=127.0.0.1'], env=self.env,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        self.report['http'] = self.wait(lambda: self.http(port))
        self.report['port'] = port

    def cleanup(self):
        errors = []

        def attempt(action):
            try:
                action()
            except (Exception, KeyboardInterrupt) as error:
                errors.append(str(error))

        if self.forward:
            def close_forward():
                self.forward.terminate()
                try:
                    self.forward.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.forward.kill()
                    self.forward.wait(timeout=10)
            attempt(close_forward)
        if self.log:
            attempt(self.log.close)
        if self.profile:
            attempt(lambda: self.cmd(['minikube', 'delete', '-p', self.name], 300))
            attempt(lambda: self.verify_profile_absent())
        if self.started:
            # The store was created exclusively for this proof. Enumerate each
            # resource, including volumes; never prune or reset a runtime.
            for kind, listing, deletion in (
                ('container', ['ls', '-aq'], ['rm', '-f']),
                ('image', ['ls', '-aq'], ['rm', '-f']),
                ('network', ['ls', '--format', '{{.Name}}'], ['rm']),
                ('volume', ['ls', '-q'], ['rm'])):
                def remove(kind=kind, listing=listing, deletion=deletion):
                    def owned():
                        # Podman's built-in default network is not a stored resource and cannot be removed.
                        return [item for item in self.cmd(['podman', kind, *listing]).split()
                                if (kind, item) != ('network', 'podman')]
                    ids = owned()
                    self.report.setdefault('owned_resources', {})[kind] = ids
                    for resource in dict.fromkeys(ids):
                        attempt(lambda resource=resource: self.cmd(['podman', kind, *deletion, resource]))
                    left = owned()
                    self.report.setdefault('remaining_resources', {})[kind] = left
                    if left:
                        raise RuntimeError(f'Remaining {kind}: {left}')
                attempt(remove)
            if not errors:
                # Rootless layers contain subordinate-UID files. Re-enter the user
                # namespace for deletion, without host root.
                attempt(lambda: self.cmd(['podman', 'unshare', 'rm', '-rf', '--', self.graphroot]))
        if not errors:
            attempt(lambda: shutil.rmtree(self.runtime))
            attempt(lambda: shutil.rmtree(self.state))
            if self.state.exists():
                errors.append(f'Owned state remains: {self.state}')
        self.report['cleanup'] = {'status': 'failed' if errors else 'passed', 'errors': errors,
                                  'remaining_state': str(self.state) if self.state.exists() else None,
                                  'remaining_runtime_state': str(self.runtime) if self.runtime.exists() else None}
        self.report['disk_free_after'] = shutil.disk_usage(self.state.parent).free
        self.report['disk_note'] = 'Free bytes measured separately; no disk compaction performed.'
        return not errors

    def verify_profile_absent(self):
        for directory in ('profiles', 'machines'):
            path = Path(self.env['MINIKUBE_HOME']) / '.minikube' / directory / self.name
            if path.exists():
                raise RuntimeError(f'Owned minikube state remains: {path}')


def interrupted(signum, frame):
    raise InterruptedError(f'Interrupted by signal {signum}')


def run_proof():
    report = {'status': 'unavailable'}
    try:
        runtime, env, evidence = preflight()
        report.update(evidence)
    except Exception as error:
        report['error'] = str(error)
        return 2, report
    try:
        proof = Proof(runtime, env, report)
    except OSError as error:
        report.update(status='failed', error=str(error))
        return 1, report
    handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    code = 1
    try:
        proof.execute()
        report['status'] = 'passed'
        code = 0
    except (Exception, KeyboardInterrupt) as error:
        report.update(status='failed', error=str(error))
    finally:
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if not proof.cleanup():
                report['status'] = 'cleanup-failed'
                code = 3
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    return code, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, help='Write JSON evidence, including cleanup and recovery paths')
    args = parser.parse_args()
    code, report = run_proof()
    output = json.dumps(report, indent=2) + '\n'
    if args.report:
        args.report.write_text(output)
    print(output, end='')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
