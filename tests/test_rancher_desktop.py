import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows Rancher Desktop provisioning")
class RancherDesktopTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="rancher desktop ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / "source with spaces"
        self.script_name = ".chezmoiscripts/run_after_25-rancher-desktop.ps1.tmpl"
        target = self.source / self.script_name
        target.parent.mkdir(parents=True)
        shutil.copy2(self.repo / "home" / self.script_name, target)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.state = self.root / "cluster.json"
        self.initial = {
            "kubernetes": {"enabled": False, "version": "keep-version"},
            "containerEngine": {"name": "keep-engine"},
            "network": {"port": 12345},
            "workloads": {"sentinel": {"uid": "existing-workload", "replicas": 2}},
            "currentContext": "unrelated-cluster",
            "starts": 0,
            "probes": 0,
        }
        self.state.write_text(json.dumps(self.initial), encoding="utf-8")
        self.sleeps = self.root / "sleeps.txt"
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"),
            "LOCALAPPDATA": str(self.root / "local app data"),
            "RANCHER_TEST_PROGRAMFILES": str(self.root / "Program Files"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            # Neither lookup nor fallback may discover the host's real Rancher tools.
            "PATH": str(self.commands),
            "RANCHER_TEST_STATE": str(self.state),
            "RANCHER_TEST_SLEEPS": str(self.sleeps),
            "RANCHER_TEST_MODE": "ready",
        })
        shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        wrapper = self.root / "isolated-interpreter.ps1"
        # Virtualize time only at the interpreter boundary, not in production.
        wrapper.write_text('''param([string]$Script)
# Windows PowerShell reconstructs ProgramFiles at startup; override it inside this fixture.
$env:ProgramFiles = $env:RANCHER_TEST_PROGRAMFILES
$global:RancherTestNow = [datetime]'2026-01-01T00:00:00Z'
function global:Get-Date { $global:RancherTestNow }
function global:Start-Sleep {
    param([int]$Seconds)
    if ($Seconds -le 0) { throw 'Readiness wait must advance time' }
    $global:RancherTestNow = $global:RancherTestNow.AddSeconds($Seconds)
    Add-Content -LiteralPath $env:RANCHER_TEST_SLEEPS -Value $Seconds
}
& $Script
''', encoding="utf-8-sig")
        self.config = self.root / "chezmoi.toml"
        self.config.write_text(
            "[interpreters.ps1]\ncommand = " + json.dumps(str(shell)) +
            "\nargs = " + json.dumps(["-NoLogo", "-NoProfile", "-NonInteractive",
                                      "-ExecutionPolicy", "Bypass", "-File", str(wrapper)]) + "\n",
            encoding="utf-8",
        )
        self.fake = self.root / "rancher-tool.py"
        self.fake.write_text('''import json
import os
from pathlib import Path
import sys

path = Path(os.environ["RANCHER_TEST_STATE"])
state = json.loads(path.read_text(encoding="utf-8"))
tool, *args = sys.argv[1:]
mode = os.environ["RANCHER_TEST_MODE"]
def save():
    path.write_text(json.dumps(state), encoding="utf-8")

if tool == "rdctl":
    if args != ["start", "--kubernetes.enabled=true", "--no-modal-dialogs"]:
        print("Unsupported settings change or destructive action", file=sys.stderr)
        sys.exit(87)
    if mode == "start-failure":
        print("Simulated Rancher startup failure", file=sys.stderr)
        sys.exit(23)
    state["kubernetes"]["enabled"] = True
    state["starts"] += 1
    save()
    sys.exit(0)

if (args[:2] != ["--context", "rancher-desktop"] or
        not args[2].startswith("--request-timeout=") or args[3:] != ["get", "nodes", "-o", "json"]):
    print("Readiness must query the explicit Rancher context", file=sys.stderr)
    sys.exit(87)
timeout = int(args[2].split("=", 1)[1].removesuffix("s"))
if timeout <= 0 or timeout > 5:
    sys.exit(87)
state["probes"] += 1
save()
if not state["kubernetes"]["enabled"]:
    print("Kubernetes is disabled", file=sys.stderr)
    sys.exit(1)
if mode == "unreachable" or (mode == "delayed" and state["probes"] == 1):
    print("connection refused: simulated API unavailable", file=sys.stderr)
    sys.exit(1)
if mode == "malformed":
    print("not JSON")
    sys.exit(0)
if mode == "empty":
    print(json.dumps({"items": []}))
    sys.exit(0)
ready = mode != "not-ready" and not (mode == "delayed" and state["probes"] == 2)
print(json.dumps({"items": [{"metadata": {"name": "rancher-node"}, "status": {
    "conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}]}))
''', encoding="utf-8")
        self.install_shims(self.commands)

    def install_shims(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        for tool in ("rdctl", "kubectl"):
            (directory / (tool + ".cmd")).write_text(
                f'@echo off\n"{sys.executable}" "{self.fake}" {tool} %*\nexit /b %errorlevel%\n',
                encoding="utf-8",
            )

    def apply(self, *args, check=True):
        result = subprocess.run([
            self.chezmoi, "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", "apply", *args,
        ], env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def cluster(self):
        return json.loads(self.state.read_text(encoding="utf-8"))

    def assert_preserved(self):
        state = self.cluster()
        for key in ("containerEngine", "network", "workloads", "currentContext"):
            self.assertEqual(state[key], self.initial[key])
        self.assertEqual(state["kubernetes"]["version"], self.initial["kubernetes"]["version"])

    def test_enables_kubernetes_and_repeated_apply_preserves_cluster(self):
        for count in (1, 2):
            self.apply()
            self.assertTrue(self.cluster()["kubernetes"]["enabled"])
            self.assertEqual(self.cluster()["starts"], count)
            self.assertEqual(self.cluster()["probes"], count)
            self.assert_preserved()
        self.assertFalse(self.sleeps.exists())

    def test_delayed_api_and_node_readiness_waits_until_usable(self):
        self.env["RANCHER_TEST_MODE"] = "delayed"
        self.apply()
        self.assertEqual(self.cluster()["probes"], 3)
        self.assertEqual(len(self.sleeps.read_text().splitlines()), 2)
        self.assert_preserved()

    def test_permanently_unusable_cluster_times_out_with_diagnostics(self):
        for mode, diagnostic in (("unreachable", "connection refused"),
                                 ("not-ready", "Ready node"),
                                 ("empty", "Ready node"), ("malformed", "node data")):
            with self.subTest(mode=mode):
                self.env["RANCHER_TEST_MODE"] = mode
                self.state.write_text(json.dumps(self.initial), encoding="utf-8")
                self.sleeps.unlink(missing_ok=True)
                result = self.apply(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("300", result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stdout + result.stderr)
                waited = sum(int(line) for line in self.sleeps.read_text().splitlines())
                self.assertEqual(waited, 300)
                self.assertGreater(self.cluster()["probes"], 1)
                self.assertLessEqual(self.cluster()["probes"], 60)
                self.assert_preserved()

    def test_startup_failure_is_not_hidden_or_retried(self):
        self.env["RANCHER_TEST_MODE"] = "start-failure"
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("23", result.stdout + result.stderr)
        self.assertEqual(self.cluster(), self.initial)
        self.assertFalse(self.sleeps.exists())

    def test_missing_tools_fail_before_startup(self):
        for tool in ("rdctl", "kubectl"):
            with self.subTest(tool=tool):
                path = self.commands / (tool + ".cmd")
                path.unlink()
                result = self.apply(check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(tool, result.stdout + result.stderr)
                self.assertEqual(self.cluster(), self.initial)
                self.install_shims(self.commands)

    def test_machine_and_per_user_installation_paths(self):
        for variable, prefix in (("RANCHER_TEST_PROGRAMFILES", Path("Rancher Desktop")),
                                 ("LOCALAPPDATA", Path("Programs/Rancher Desktop"))):
            for suffix in ("resources/resources/win32/bin",):
                with self.subTest(variable=variable, suffix=suffix):
                    for path in self.commands.iterdir():
                        path.unlink()
                    directory = Path(self.env[variable]) / prefix / suffix
                    self.install_shims(directory)
                    self.apply()
                    self.assertTrue(self.cluster()["kubernetes"]["enabled"])
                    self.assert_preserved()
                    shutil.rmtree(directory)

    def test_dry_run_does_not_start_or_probe_rancher(self):
        self.apply("--dry-run")
        self.assertEqual(self.cluster(), self.initial)
        self.assertFalse(self.sleeps.exists())

    def test_non_windows_template_is_empty(self):
        for platform in ("linux", "darwin"):
            with self.subTest(platform=platform):
                body = (self.source / self.script_name).read_text(encoding="utf-8")
                template = ('{{ template "rancher" (dict "chezmoi" (dict "os" "' +
                            platform + '")) }}{{ define "rancher" }}' + body + '{{ end }}')
                result = subprocess.run([
                    self.chezmoi, "--source", str(self.source), "--destination", str(self.home),
                    "--config", str(self.config), "execute-template", template,
                ], env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), "")
                self.assertEqual(self.cluster(), self.initial)


if __name__ == "__main__":
    unittest.main()
