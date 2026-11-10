import contextlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location('smoke_linux_minikube', Path(__file__).with_name('smoke_linux_minikube.py'))
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)

ISOLATION_KEYS = ('CONTAINERS_STORAGE_CONF', 'CONTAINERS_CONF', 'MINIKUBE_HOME', 'KUBECONFIG')
OWNER_KEYS = ('DOCKER_HOST', 'CONTAINER_HOST', 'MINIKUBE_PROFILE', 'MINIKUBE_ROOTLESS')

# Executable command fixture: never invokes Podman, a cluster, or an HTTP server.
FIXTURE = r'''
import json, os, pathlib, re, sys
args = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
keys = json.loads(os.environ['FIXTURE_ENV_KEYS'])
with (root / 'calls').open('a') as out:
    out.write(json.dumps({'args': args, 'env': {key: os.environ.get(key) for key in keys}}) + '\n')
if os.environ.get('FAIL_COMMAND') and os.environ['FAIL_COMMAND'] in ' '.join(args):
    print('fixture failure', file=sys.stderr)
    sys.exit(42)
inventory = root / 'inventory'
resources = json.loads(inventory.read_text()) if inventory.exists() else {}
if args[:2] == ['podman', 'info']:
    resources = {'container': ['container-owned'], 'image': ['image-owned'],
                 'network': ['network-owned'], 'volume': ['volume-owned']}
    storage = pathlib.Path(os.environ['CONTAINERS_STORAGE_CONF']).read_text()
    print(json.dumps({'host': {'security': {'rootless': True}, 'cgroupVersion': 'v2'},
                      'store': {'graphRoot': re.search(r'^graphroot = "(.*)"$', storage, re.M).group(1)}}))
elif args[:2] == ['podman', 'run']:
    print('dotfiles-kubernetes-ok')
elif args[:2] == ['kubectl', 'version']:
    print(json.dumps({'serverVersion': {'gitVersion': 'v1.37.0'}}))
elif len(args) > 2 and args[0] == 'podman' and args[1] in resources:
    if args[2] == 'ls':
        # Podman always lists its built-in default network.
        print('\n'.join((['podman'] if args[1] == 'network' else []) + resources[args[1]]))
    elif args[2] == 'rm':
        resources[args[1]] = [item for item in resources[args[1]] if item != args[-1]]
inventory.write_text(json.dumps(resources))
'''


@contextlib.contextmanager
def fedora_host(controllers='cpuset cpu io memory pids', subordinate_ids='1000:100000:65536\n',
                tool='/fixture/tool', command=None):
    """Patch the host facts preflight reads; nothing inside may touch the real filesystem."""
    def read_text(path, *args, **kwargs):
        return controllers + '\n' if path.name == 'cgroup.controllers' else subordinate_ids

    def run(args, env, timeout=120):
        if args[:2] == ['minikube', 'version']:
            return 'v1.39.0'
        if args[:2] == ['kubectl', 'version']:
            return json.dumps({'clientVersion': {'gitVersion': 'v1.37.2'}})
        return ''

    spec = SimpleNamespace(loader=Mock())
    host = SimpleNamespace(inspect_host=lambda: {'supported': True})
    with contextlib.ExitStack() as stack:
        for target, name, options in (
                (smoke.importlib.util, 'spec_from_file_location', {'return_value': spec}),
                (smoke.importlib.util, 'module_from_spec', {'return_value': host}),
                (smoke.os, 'getuid', {'create': True, 'return_value': 1000}),
                (smoke.Path, 'is_dir', {'return_value': True}),
                (smoke.Path, 'is_symlink', {'return_value': False}),
                (smoke.Path, 'stat', {'return_value': SimpleNamespace(st_uid=1000, st_mode=0o700)}),
                (smoke.Path, 'is_file', {'return_value': True}),
                (smoke.Path, 'read_text', {'autospec': True, 'side_effect': read_text}),
                (smoke.pwd, 'getpwuid', {'return_value': SimpleNamespace(pw_name='user')}),
                (smoke.shutil, 'which', {'return_value': tool}),
                (smoke, 'command', {'side_effect': command or run})):
            stack.enter_context(patch.object(target, name, **options))
        yield


@unittest.skipIf(os.name == "nt", "POSIX executable fixtures require a Unix host")
class LinuxMinikubeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        binaries = self.root / 'bin'
        binaries.mkdir()
        fixture = binaries / 'fixture'
        fixture.write_text('#!' + sys.executable + '\n' + FIXTURE)
        fixture.chmod(0o755)
        for name in ('podman', 'minikube', 'kubectl'):
            (binaries / name).symlink_to(fixture)
        self.host_env = os.environ.copy()
        self.host_env.update(PATH=str(binaries), FIXTURE_ROOT=str(self.root),
                             FIXTURE_ENV_KEYS=json.dumps(ISOLATION_KEYS + OWNER_KEYS),
                             DOCKER_HOST='unix:///user/docker.sock', CONTAINER_HOST='unix:///user/podman.sock',
                             MINIKUBE_PROFILE='user', MINIKUBE_ROOTLESS='false', MINIKUBE_HOME='/user/minikube',
                             KUBECONFIG='/user/kubeconfig', CONTAINERS_STORAGE_CONF='/user/storage.conf',
                             CONTAINERS_CONF='/user/containers.conf')
        self.proof = smoke.Proof(self.root, self.host_env, {}, state_parent=self.root)
        self.forward = Mock()
        self.forward.poll.return_value = None
        self.forward_env = None

    def calls(self):
        path = self.root / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def commands(self):
        return [call['args'] for call in self.calls()]

    @contextlib.contextmanager
    def cluster(self):
        """Replace the port-forward process and the HTTP request, which no fixture command can serve."""
        real_popen = subprocess.Popen
        def popen(args, **kwargs):
            if args[:2] == ['kubectl', 'port-forward']:
                self.forward_env = kwargs['env']
                return self.forward
            return real_popen(args, **kwargs)
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b'dotfiles-kubernetes-ok\n'
        self.opener = Mock()
        self.opener.open.return_value = response
        with patch.object(smoke.subprocess, 'Popen', side_effect=popen), patch.object(
                smoke.urllib.request, 'build_opener', return_value=self.opener):
            yield

    def execute(self):
        with self.cluster():
            self.proof.execute()
        self.assertIn('http://127.0.0.1:', self.opener.open.call_args.args[0])

    def run_proof(self, **env):
        """Run the whole proof against fixture commands, sharing its report with the owned Proof."""
        real_proof = smoke.Proof
        def proof(runtime, host_env, report):
            self.proof = real_proof(runtime, host_env, report, state_parent=self.root)
            return self.proof
        with patch.object(smoke, 'preflight', return_value=(self.root, {**self.host_env, **env}, {})), patch.object(
                smoke, 'Proof', side_effect=proof), self.cluster():
            return smoke.run_proof()

    def test_build_run_cluster_http_and_cleanup_order(self):
        sentinel = self.root / 'user-context'
        sentinel.write_text('preserve')
        self.execute()
        state = self.proof.state
        real_command = smoke.command
        def cleanup_command(args, env, timeout=120):
            if args[:2] == ['minikube', 'delete']:
                self.forward.wait.assert_called_once()
            return real_command(args, env, timeout)
        with patch.object(smoke, 'command', side_effect=cleanup_command):
            self.assertTrue(self.proof.cleanup(), self.proof.report)
        self.assertEqual(self.proof.report['http'], 'dotfiles-kubernetes-ok')
        self.assertFalse(state.exists())
        self.assertFalse(self.proof.runtime.exists())
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.forward.terminate.assert_called_once()
        self.forward.wait.assert_called_once_with(timeout=10)
        calls = self.commands()
        start = next(call for call in calls if call[:2] == ['minikube', 'start'])
        for flag in ('--driver=podman', '--rootless', '--container-runtime=containerd',
                     '--kubernetes-version=v1.37.0'):
            self.assertIn(flag, start)
        image = 'localhost/' + self.proof.name + ':proof'
        self.assertTrue(any(call[:2] == ['podman', 'build'] for call in calls))
        self.assertIn(['podman', 'run', '--rm', image, 'cat', '/www/index.html'], calls)
        archive = Path(next(call for call in calls if call[:2] == ['podman', 'save'])[-2])
        self.assertEqual(archive.parent, state)
        self.assertIn(['minikube', '-p', self.proof.name, 'image', 'load', str(archive)], calls)
        self.assertIn(['kubectl', 'create', 'deployment', self.proof.name, '--image=' + image], calls)
        delete_index = next(i for i, call in enumerate(calls) if call[:2] == ['minikube', 'delete'])
        unshare_index = next(i for i, call in enumerate(calls) if call[:2] == ['podman', 'unshare'])
        self.assertEqual(calls[unshare_index][2:], ['rm', '-rf', '--', str(state / 'storage')])
        self.assertEqual(unshare_index, len(calls) - 1)
        for resource in ('container', 'image', 'network', 'volume'):
            removals = [i for i, call in enumerate(calls) if call[:3] == ['podman', resource, 'rm']]
            self.assertTrue(removals)
            self.assertLess(delete_index, min(removals))
            self.assertEqual(self.proof.report['owned_resources'][resource], [resource + '-owned'])
            self.assertEqual(self.proof.report['remaining_resources'][resource], [])
        self.assertNotIn(['podman', 'network', 'rm', 'podman'], calls)
        self.assertEqual(json.loads((self.root / 'inventory').read_text()),
                         {key: [] for key in ('container', 'image', 'network', 'volume')})
        for call in calls:
            self.assertNotIn('prune', call)
            self.assertNotIn('system reset', ' '.join(call))
            self.assertFalse(call[0] == 'minikube' and '--all' in call)

    def test_every_command_uses_private_state_instead_of_owner_defaults(self):
        self.execute()
        state = self.proof.state
        self.assertTrue(self.proof.cleanup(), self.proof.report)
        private = {'CONTAINERS_STORAGE_CONF': str(state / 'storage.conf'),
                   'CONTAINERS_CONF': str(state / 'containers.conf'),
                   'MINIKUBE_HOME': str(state / 'minikube'), 'KUBECONFIG': str(state / 'kubeconfig')}
        environments = [call['env'] for call in self.calls()] + [self.forward_env]
        self.assertEqual({call['args'][0] for call in self.calls()}, {'podman', 'minikube', 'kubectl'})
        for environment in environments:
            for key, value in private.items():
                self.assertEqual(environment[key], value)
            for key in OWNER_KEYS:
                self.assertIsNone(environment.get(key))
        self.assertEqual(self.proof.report['storage_conf'], private['CONTAINERS_STORAGE_CONF'])
        self.assertEqual(self.proof.report['containers_conf'], private['CONTAINERS_CONF'])

    def test_private_configuration_keeps_storage_and_networks_inside_owned_directories(self):
        storage = (self.proof.state / 'storage.conf').read_text()
        self.assertIn('driver = "overlay"', storage)
        self.assertIn(f'graphroot = "{self.proof.state}/storage"', storage)
        self.assertIn(f'runroot = "{self.proof.runtime}/storage"', storage)
        self.assertIn(f'network_config_dir = "{self.proof.state}/networks"',
                      (self.proof.state / 'containers.conf').read_text())

    def test_workload_failure_still_cleans_owned_resources(self):
        self.proof.env['FAIL_COMMAND'] = 'rollout status'
        with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
            self.execute()
        self.assertTrue(self.proof.cleanup(), self.proof.report)
        self.assertFalse(self.proof.state.exists())

    def test_failed_cluster_start_fails_the_proof_without_another_runtime(self):
        code, report = self.run_proof(FAIL_COMMAND='minikube start')
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('fixture failure', report['error'])
        self.assertEqual(report['cleanup']['status'], 'passed')
        self.assertFalse(self.proof.state.exists())
        calls = self.commands()
        self.assertIn(['minikube', 'delete', '-p', self.proof.name], calls)
        self.assertEqual({call[0] for call in calls}, {'podman', 'minikube'})
        self.assertFalse(any('docker' in argument for call in calls for argument in call))

    def test_remaining_resource_reports_incomplete_cleanup_and_keeps_state(self):
        code, report = self.run_proof(FAIL_COMMAND='volume rm')
        self.assertEqual(code, 3)
        self.assertEqual(report['status'], 'cleanup-failed')
        self.assertEqual(report['state'], str(self.proof.state))
        self.assertEqual(report['cleanup']['remaining_state'], str(self.proof.state))
        self.assertTrue(self.proof.state.exists())
        self.assertEqual(report['owned_resources']['volume'], ['volume-owned'])
        self.assertEqual(report['remaining_resources']['volume'], ['volume-owned'])
        self.assertIn('volume-owned', (self.root / 'inventory').read_text())
        self.assertFalse(any(call[:2] == ['podman', 'unshare'] for call in self.commands()))

    def test_signals_unwind_through_one_cleanup_and_restore_handlers(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            (self.root / 'calls').unlink(missing_ok=True)
            self.proof = smoke.Proof(self.root, self.host_env, {}, state_parent=self.root)
            self.execute()
            with self.subTest(signal=sig), patch.object(smoke, 'preflight', return_value=(self.root, {}, {})), patch.object(
                    smoke, 'Proof', return_value=self.proof), patch.object(self.proof, 'execute',
                    side_effect=lambda: smoke.interrupted(sig, None)):
                original = signal.getsignal(sig)
                code, report = smoke.run_proof()
                self.assertEqual(code, 1)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(signal.getsignal(sig), original)
                self.assertEqual(self.proof.report['cleanup']['status'], 'passed')
                self.assertFalse(self.proof.state.exists())
                self.assertFalse(self.proof.runtime.exists())
                self.assertEqual(json.loads((self.root / 'inventory').read_text())['volume'], [])
                self.assertEqual(sum(call[:2] == ['podman', 'unshare'] for call in self.commands()), 1)
            self.forward.reset_mock()

    def test_cleanup_failure_exit_contract(self):
        with patch.object(smoke, 'preflight', return_value=(self.root, {}, {})), patch.object(
                smoke, 'Proof', return_value=self.proof), patch.object(self.proof, 'execute'), patch.object(
                self.proof, 'cleanup', return_value=False):
            code, report = smoke.run_proof()
        self.assertEqual(code, 3)
        self.assertEqual(report['status'], 'cleanup-failed')

    def test_unsupported_host_never_starts_a_process(self):
        with patch('platform.system', return_value='Darwin'), patch.object(smoke.subprocess, 'run') as run:
            code, report = smoke.run_proof()
        self.assertEqual(code, 2)
        self.assertEqual(report['status'], 'unavailable')
        run.assert_not_called()

    def test_missing_delegated_controller_is_unavailable_and_named(self):
        with fedora_host(controllers='cpuset cpu io memory'), patch.object(smoke, 'Proof') as proof:
            code, report = smoke.run_proof()
        self.assertEqual(code, 2)
        self.assertEqual(report['status'], 'unavailable')
        self.assertIn('pids', report['error'])
        proof.assert_not_called()

    def test_too_few_subordinate_ids_is_unavailable(self):
        with fedora_host(subordinate_ids='1000:100000:65535\n'), patch.object(smoke, 'Proof') as proof:
            code, report = smoke.run_proof()
        self.assertEqual(code, 2)
        self.assertIn('65536 subordinate IDs', report['error'])
        proof.assert_not_called()

    def test_missing_optional_controller_continues_with_a_warning(self):
        with fedora_host(controllers='cpu memory pids'):
            runtime, env, evidence = smoke.preflight()
        self.assertEqual(evidence['delegated_controllers'], ['cpu', 'memory', 'pids'])
        self.assertEqual(len(evidence['warnings']), 1)
        self.assertIn('cpuset', evidence['warnings'][0])
        self.assertIn('io', evidence['warnings'][0])
        with patch.object(smoke, 'preflight', return_value=(self.root, self.host_env, evidence)), patch.object(
                smoke, 'Proof', return_value=self.proof), self.cluster():
            code, report = smoke.run_proof()
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['warnings'], evidence['warnings'])

    def test_full_delegation_reports_no_warning(self):
        with fedora_host():
            evidence = smoke.preflight()[2]
        self.assertEqual(evidence['warnings'], [])

    def test_preflight_rejects_missing_prerequisite_before_runtime(self):
        with fedora_host(tool=None), patch.object(smoke.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Missing prerequisite: podman'):
                smoke.preflight()
            run.assert_not_called()

    def test_missing_user_session_fails_before_podman_or_minikube(self):
        calls = []
        def command(args, env, timeout):
            calls.append(args)
            if args[-1] == 'show-environment':
                raise RuntimeError('missing systemd user session prerequisite')
            return ''
        with fedora_host(command=command):
            with self.assertRaisesRegex(RuntimeError, 'prerequisite'):
                smoke.preflight()
        self.assertFalse(any(args[0] in ('podman', 'minikube', 'kubectl') for args in calls))


class LinuxMinikubeEligibilityTest(unittest.TestCase):
    def test_unsupported_host_does_not_need_posix_modules_or_processes(self):
        with patch('platform.system', return_value='Windows'), patch.object(smoke, 'pwd', None), patch.object(
                smoke.subprocess, 'run') as run:
            code, report = smoke.run_proof()
        self.assertEqual(code, 2)
        self.assertEqual(report['status'], 'unavailable')
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
