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

# Executable command fixture: never invokes a daemon, cluster, or HTTP server.
FIXTURE = r'''
import json, os, pathlib, sys
args = [pathlib.Path(sys.argv[0]).name, *sys.argv[1:]]
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root / 'calls').open('a') as out:
    out.write(json.dumps(args) + '\n')
if os.environ.get('FAIL_COMMAND') and os.environ['FAIL_COMMAND'] in ' '.join(args):
    print('fixture failure', file=sys.stderr)
    sys.exit(42)
inventory = root / 'inventory'
resources = json.loads(inventory.read_text()) if inventory.exists() else {}
if args[:2] == ['docker', 'info']:
    resources = {'container': ['container-owned'], 'image': ['image-owned'],
                 'network': ['network-owned'], 'volume': ['volume-owned']}
    print(json.dumps({'SecurityOptions': ['name=rootless'], 'CgroupVersion': '2',
                      'DockerRootDir': str(pathlib.Path(os.environ['DOCKER_CONFIG']).parent / 'data')}))
elif args[:2] == ['docker', 'run']:
    print('dotfiles-kubernetes-ok')
elif args[:3] == ['systemctl', '--user', 'show']:
    print('yes')
elif args[:2] == ['kubectl', 'version']:
    print(json.dumps({'serverVersion': {'gitVersion': 'v1.37.0'}}))
elif len(args) > 2 and args[0] == 'docker' and args[1] in resources:
    if args[2] == 'ls':
        print('\n'.join(resources[args[1]]))
    elif args[2] == 'rm':
        resources[args[1]] = [item for item in resources[args[1]] if item != args[-1]]
inventory.write_text(json.dumps(resources))
'''


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
        for name in ('docker', 'minikube', 'kubectl', 'systemd-run', 'systemctl', 'rootlesskit'):
            (binaries / name).symlink_to(fixture)
        env = os.environ.copy()
        env.update(PATH=str(binaries), FIXTURE_ROOT=str(self.root), DOCKER_CONTEXT='user',
                   DOCKER_TLS_VERIFY='1', KUBECONFIG='/user/kubeconfig')
        self.proof = smoke.Proof(self.root, env, {}, state_parent=self.root)
        self.forward = Mock()
        self.forward.poll.return_value = None

    def calls(self):
        path = self.root / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def execute(self):
        real_popen = subprocess.Popen
        def popen(args, **kwargs):
            if args[:2] == ['kubectl', 'port-forward']:
                return self.forward
            return real_popen(args, **kwargs)
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        response.read.return_value = b'dotfiles-kubernetes-ok\n'
        opener = Mock()
        opener.open.return_value = response
        with patch.object(smoke.subprocess, 'Popen', side_effect=popen), patch.object(
                smoke.urllib.request, 'build_opener', return_value=opener):
            self.proof.execute()
        self.assertIn('http://127.0.0.1:', opener.open.call_args.args[0])

    def test_build_run_cluster_http_and_cleanup_order(self):
        sentinel = self.root / 'user-context'
        sentinel.write_text('preserve')
        self.execute()
        real_command = smoke.command
        def cleanup_command(args, env, timeout=120):
            if args[:2] == ['minikube', 'delete']:
                self.forward.wait.assert_called_once()
            return real_command(args, env, timeout)
        with patch.object(smoke, 'command', side_effect=cleanup_command):
            self.assertTrue(self.proof.cleanup(), self.proof.report)
        self.assertEqual(self.proof.report['http'], 'dotfiles-kubernetes-ok')
        self.assertFalse(self.proof.state.exists())
        self.assertFalse(self.proof.runtime.exists())
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertNotIn('DOCKER_CONTEXT', self.proof.env)
        self.assertNotIn('DOCKER_TLS_VERIFY', self.proof.env)
        self.forward.terminate.assert_called_once()
        self.forward.wait.assert_called_once_with(timeout=10)
        calls = self.calls()
        start = next(call for call in calls if call[:2] == ['minikube', 'start'])
        for flag in ('--driver=docker', '--container-runtime=containerd', '--kubernetes-version=v1.37.0'):
            self.assertIn(flag, start)
        service = calls[0]
        self.assertIn('--property=Delegate=yes', service)
        self.assertTrue(any('buildx' in call and 'build' in call and '--builder' in call for call in calls))
        self.assertTrue(any(call[:2] == ['docker', 'run'] for call in calls))
        delete_index = next(i for i, call in enumerate(calls) if call[:2] == ['minikube', 'delete'])
        stop_index = next(i for i, call in enumerate(calls) if call[:3] == ['systemctl', '--user', 'stop'])
        self.assertLess(delete_index, stop_index)
        for resource in ('container', 'image', 'network', 'volume'):
            removals = [i for i, call in enumerate(calls) if call[:3] == ['docker', resource, 'rm']]
            self.assertTrue(removals)
            self.assertLess(max(removals), stop_index)
        self.assertEqual(json.loads((self.root / 'inventory').read_text()),
                         {key: [] for key in ('container', 'image', 'network', 'volume')})
        self.assertFalse(any('prune' in call or '--all' in call and call[0] == 'minikube' for call in calls))

    def test_workload_failure_still_cleans_owned_resources(self):
        self.proof.env['FAIL_COMMAND'] = 'rollout status'
        with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
            self.execute()
        self.assertTrue(self.proof.cleanup(), self.proof.report)
        self.assertFalse(self.proof.state.exists())

    def test_cleanup_failure_preserves_exact_resources_and_state(self):
        self.execute()
        self.proof.env['FAIL_COMMAND'] = 'volume rm'
        self.assertFalse(self.proof.cleanup())
        report = self.proof.report
        self.assertEqual(report['cleanup']['remaining_state'], str(self.proof.state))
        self.assertTrue(self.proof.state.exists())
        self.assertIn('volume-owned', str(report))
        self.assertTrue(any(call[:3] == ['systemctl', '--user', 'stop'] for call in self.calls()))
        self.assertIn('volume-owned', (self.root / 'inventory').read_text())
        self.assertEqual(report['remaining_resources']['volume ls -q'], ['volume-owned'])

    def test_signals_unwind_through_cleanup_and_restore_handlers(self):
        env = self.proof.env.copy()
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            self.proof = smoke.Proof(self.root, env, {}, state_parent=self.root)
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

    def test_preflight_rejects_missing_prerequisite_before_runtime(self):
        spec = SimpleNamespace(loader=Mock())
        host = SimpleNamespace(inspect_host=lambda: {'supported': True})
        with patch.object(smoke.importlib.util, 'spec_from_file_location', return_value=spec), patch.object(
                smoke.importlib.util, 'module_from_spec', return_value=host), patch.object(
                smoke.os, 'getuid', return_value=1000), patch.object(smoke.Path, 'is_dir', return_value=True), patch.object(
                smoke.Path, 'is_symlink', return_value=False), patch.object(smoke.Path, 'stat', return_value=SimpleNamespace(
                    st_uid=1000, st_mode=0o700)), patch.object(smoke.Path, 'is_file', return_value=True), patch.object(
                smoke.Path, 'read_text', return_value='1000:100000:65536\n'), patch.object(
                smoke.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='user')), patch.object(
                smoke.shutil, 'which', return_value=None), patch.object(smoke.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Missing prerequisite'):
                smoke.preflight()
            run.assert_not_called()

    def test_rootless_restrictions_fail_before_daemon_start(self):
        spec = SimpleNamespace(loader=Mock())
        host = SimpleNamespace(inspect_host=lambda: {'supported': True})
        for failure in ('show-environment', 'check', 'true'):
            calls = []
            def command(args, env, timeout):
                calls.append(args)
                if args[-1] == failure:
                    raise RuntimeError('missing systemd/rootless/AppArmor prerequisite')
                return ''
            with self.subTest(failure=failure), patch.object(
                    smoke.importlib.util, 'spec_from_file_location', return_value=spec), patch.object(
                    smoke.importlib.util, 'module_from_spec', return_value=host), patch.object(
                    smoke.os, 'getuid', return_value=1000), patch.object(smoke.Path, 'is_dir', return_value=True), patch.object(
                    smoke.Path, 'is_symlink', return_value=False), patch.object(smoke.Path, 'stat', return_value=SimpleNamespace(
                        st_uid=1000, st_mode=0o700)), patch.object(smoke.Path, 'is_file', return_value=True), patch.object(
                    smoke.Path, 'read_text', return_value='1000:100000:65536\n'), patch.object(
                    smoke.pwd, 'getpwuid', return_value=SimpleNamespace(pw_name='user')), patch.object(
                    smoke.shutil, 'which', return_value='/fixture/tool'), patch.object(smoke, 'command', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'prerequisite'):
                    smoke.preflight()
                self.assertFalse(any(args[0] in ('systemd-run', 'minikube', 'dockerd-rootless.sh') for args in calls))


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
