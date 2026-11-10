"""Explicit Ubuntu Studio rootless build/run and minikube HTTP proof.

Run after explicit Linux application and `mise run linux-kubernetes`.
No installation or persistent runtime setup is performed. Exit codes: 0 passed,
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
    env = os.environ.copy()
    env['PATH'] = str(Path.home() / '.local/share/dotfiles/build/bin') + os.pathsep + env.get('PATH', '')
    for tool in ('docker', 'dockerd', 'dockerd-rootless.sh', 'rootlesskit', 'newuidmap', 'newgidmap',
                 'dockerd-rootless-setuptool.sh', 'slirp4netns', 'systemd-run', 'systemctl', 'minikube', 'kubectl'):
        if not shutil.which(tool, path=env['PATH']):
            raise RuntimeError(f'Missing prerequisite: {tool}')
    env['XDG_RUNTIME_DIR'] = str(runtime)
    env['DBUS_SESSION_BUS_ADDRESS'] = f'unix:path={runtime}/bus'
    command(['systemctl', '--user', 'show-environment'], env, 15)
    # Docker's check performs no setup; it checks user namespaces and AppArmor too.
    command(['dockerd-rootless-setuptool.sh', '--force', 'check'], env, 30)
    # Exercise the packaged rootlesskit AppArmor policy before launching a daemon.
    command(['rootlesskit', '--net=slirp4netns', 'true'], env, 30)
    versions = {'minikube': command(['minikube', 'version', '--short'], env, 15),
                'kubectl': json.loads(command(['kubectl', 'version', '--client', '-o', 'json'], env, 15))}
    if versions['minikube'] != 'v1.39.0' or versions['kubectl']['clientVersion']['gitVersion'] != 'v1.37.2':
        raise RuntimeError('Requires provisioned minikube v1.39.0 and kubectl v1.37.2.')
    return runtime, env, {'host': host, 'versions': versions, 'server_requested': KUBERNETES_VERSION}


class Proof:
    def __init__(self, runtime, env, report, state_parent=None):
        self.state = Path(tempfile.mkdtemp(prefix='.dotfiles-k8s-', dir=state_parent or Path.home()))
        try:
            self.runtime = Path(tempfile.mkdtemp(prefix='dotfiles-k8s-', dir=runtime))
        except OSError:
            self.state.rmdir()
            raise
        self.name = 'dotfiles-k8s-' + uuid.uuid4().hex[:12]
        self.unit = self.name + '.service'
        self.env = env.copy()
        # Do not inherit a context, TLS endpoint, builder or kubeconfig selection.
        for key in ('DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'BUILDX_BUILDER',
                    'MINIKUBE_ACTIVE_DOCKERD', 'MINIKUBE_PROFILE'):
            self.env.pop(key, None)
        self.env.update(DOCKER_HOST=f'unix://{self.runtime}/docker.sock',
                        DOCKER_CONFIG=str(self.state / 'docker-config'),
                        DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR=str(self.runtime / 'rootlesskit'),
                        XDG_RUNTIME_DIR=str(runtime), MINIKUBE_HOME=str(self.state / 'minikube'),
                        KUBECONFIG=str(self.state / 'kubeconfig'),
                        BUILDX_CONFIG=str(self.state / 'buildx'))
        (self.state / 'daemon.json').write_text('{}\n')
        self.report = report
        self.report.update(endpoint=self.env['DOCKER_HOST'], profile=self.name, unit=self.unit,
                           state=str(self.state), runtime_state=str(self.runtime), ownership='exclusive newly created rootless engine',
                           disk_free_before=shutil.disk_usage(self.state.parent).free, commands=[])
        self.started = self.profile = self.builder = False
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
        self.started = True  # A timed-out systemd-run may still have created the unit.
        self.cmd(['systemd-run', '--user', '--unit=' + self.unit, '--collect',
                  '--property=Delegate=yes', '--property=KillMode=mixed',
                  *['--setenv=' + key + '=' + self.env[key] for key in
                    ('PATH', 'XDG_RUNTIME_DIR', 'DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR')],
                  'dockerd-rootless.sh', '--host=' + self.env['DOCKER_HOST'],
                  '--data-root=' + str(self.state / 'data'), '--exec-root=' + str(self.runtime / 'exec'),
                  '--pidfile=' + str(self.state / 'docker.pid'),
                  '--config-file=' + str(self.state / 'daemon.json')])
        info = json.loads(self.wait(lambda: self.cmd(['docker', 'info', '--format', '{{json .}}'], 15)))
        if ('name=rootless' not in info['SecurityOptions'] or info['CgroupVersion'] != '2'
                or Path(info['DockerRootDir']) != self.state / 'data'):
            raise RuntimeError('Owned endpoint does not report the expected rootless data root and cgroup v2.')
        self.report['docker'] = info
        self.report['delegation'] = self.cmd(['systemctl', '--user', 'show', self.unit, '-p', 'Delegate', '--value'])
        if self.report['delegation'] != 'yes':
            raise RuntimeError('Transient service lacks cgroup delegation.')
        context = self.state / 'context'
        context.mkdir()
        (context / 'index.html').write_text('dotfiles-kubernetes-ok\n')
        (context / 'Dockerfile').write_text('FROM busybox:1.37.0\nCOPY index.html /www/index.html\nEXPOSE 8080\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n')
        self.builder = True
        self.cmd(['docker', 'buildx', 'create', '--name', self.name, '--driver', 'docker-container'])
        image = self.name + ':proof'
        self.cmd(['docker', 'buildx', 'build', '--builder', self.name, '--load', '-t', image, context], 600)
        body = self.cmd(['docker', 'run', '--rm', image, 'cat', '/www/index.html'])
        if body != 'dotfiles-kubernetes-ok':
            raise RuntimeError('Built image failed the container execution proof.')
        self.profile = True
        self.cmd(['minikube', 'start', '-p', self.name, '--driver=docker', '--container-runtime=containerd',
                  '--kubernetes-version=' + KUBERNETES_VERSION, '--delete-on-failure=false', '--wait=all', '--wait-timeout=5m'], 900)
        self.cmd(['kubectl', 'wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s'], 200)
        self.report['server'] = json.loads(self.cmd(['kubectl', 'version', '-o', 'json']))
        if self.report['server']['serverVersion']['gitVersion'] != KUBERNETES_VERSION:
            raise RuntimeError('Unexpected Kubernetes server version.')
        self.cmd(['minikube', '-p', self.name, 'image', 'load', image], 300)
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
        if self.builder:
            attempt(lambda: self.cmd(['docker', 'buildx', 'rm', '--force', self.name], 120))
        if self.started:
            # The endpoint and data directory were created exclusively for this proof.
            # Enumerate each ID, including volumes; never prune a runtime.
            for listing, deletion in (
                (['container', 'ls', '-aq'], ['container', 'rm', '-f']),
                (['image', 'ls', '-aq'], ['image', 'rm', '-f']),
                (['network', 'ls', '--filter', 'type=custom', '-q'], ['network', 'rm']),
                (['volume', 'ls', '-q'], ['volume', 'rm'])):
                def remove(listing=listing, deletion=deletion):
                    ids = self.cmd(['docker', *listing]).split()
                    self.report.setdefault('owned_resources', {})[' '.join(listing)] = ids
                    for resource in dict.fromkeys(ids):
                        attempt(lambda resource=resource: self.cmd(['docker', *deletion, resource]))
                    left = self.cmd(['docker', *listing]).split()
                    self.report.setdefault('remaining_resources', {})[' '.join(listing)] = left
                    if left:
                        raise RuntimeError(f'Remaining {listing}: {left}')
                attempt(remove)
            # Always stop our service, even if endpoint enumeration failed.
            attempt(lambda: self.cmd(['systemctl', '--user', 'stop', self.unit], 120))
            def verify_stopped():
                active = self.cmd(['systemctl', '--user', 'list-units', '--all', '--plain', '--no-legend', self.unit])
                self.report['service_after_stop'] = active
                if active:
                    raise RuntimeError(f'Owned service still active: {self.unit}: {active}')
            attempt(verify_stopped)
        if not errors:
            # Rootless layers contain subordinate-UID files. Re-enter the same UID
            # mapping for deletion after the daemon has stopped, without host root.
            attempt(lambda: self.cmd(['rootlesskit', '--net=none', 'rm', '-rf', '--', self.state / 'data']))
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
