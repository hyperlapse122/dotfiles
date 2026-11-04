import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt" and shutil.which("chezmoi"), "Windows virtualization prerequisites")
class WindowsVirtualizationTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        temporary = tempfile.TemporaryDirectory(prefix="windows virtualization ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "한글 source with spaces"
        scripts = self.source / ".chezmoiscripts"
        scripts.mkdir(parents=True)
        template = self.repo / "home/.chezmoiscripts/run_before_05-check-windows-virtualization.ps1.tmpl"
        if template.exists():
            shutil.copy2(template, scripts)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.target = self.home / ".activation-proof"
        self.target.write_text("old", encoding="utf-8")
        (self.source / "dot_activation-proof").write_text("new", encoding="utf-8")
        self.after = self.root / "after.txt"
        (scripts / "run_after_99-proof.ps1").write_text(
            "Set-Content -LiteralPath $env:ACTIVATION_AFTER -Value 'ran'\n", encoding="utf-8"
        )
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "appdata"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"), "XDG_STATE_HOME": str(self.root / "state"),
            "ACTIVATION_AFTER": str(self.after),
            "ACTIVATION_FEATURES": json.dumps({"VirtualMachinePlatform": 1, "HypervisorPlatform": 1}),
            "ACTIVATION_WSL_VERSION_EXIT": "0", "ACTIVATION_WSL_STATUS_EXIT": "0",
            "ACTIVATION_WSL_MISSING": "0", "ACTIVATION_CIM_ERROR": "0",
        })
        wsl = self.root / "wsl-probe.py"
        wsl.write_text(
            "import os, sys\n"
            "option = sys.argv[1:]\n"
            "if option == ['--version']:\n"
            "    code = os.environ['ACTIVATION_WSL_VERSION_EXIT']\n"
            "elif option == ['--status']:\n"
            "    code = os.environ['ACTIVATION_WSL_STATUS_EXIT']\n"
            "else:\n"
            "    raise SystemExit('Refusing non-query WSL invocation')\n"
            "print('Aucune distribution installee. Version par defaut: 1.')\n"
            "raise SystemExit(int(code))\n", encoding="utf-8"
        )
        wsl_command = self.root / "wsl-probe.cmd"
        wsl_command.write_text(
            f'@echo off\n"{sys.executable}" "{wsl}" %*\nexit /b %errorlevel%\n', encoding="utf-8"
        )
        self.env["ACTIVATION_WSL_COMMAND"] = str(wsl_command)
        wrapper = self.root / "isolated-interpreter.ps1"
        wrapper.write_text('''param([string]$Script)
$ErrorActionPreference = 'Stop'
function global:Get-Command {
    param([string]$Name, [object]$CommandType, [object]$ErrorAction)
    if ($Name -eq 'wsl.exe') {
        if ($env:ACTIVATION_WSL_MISSING -eq '1') { throw 'WSL missing' }
        return [pscustomobject]@{ Source = $env:ACTIVATION_WSL_COMMAND }
    }
    Microsoft.PowerShell.Core\\Get-Command @PSBoundParameters
}
function global:Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
    if ($env:ACTIVATION_CIM_ERROR -eq '1') { throw 'CIM access denied' }
    if ($ClassName -ne 'Win32_OptionalFeature') { throw 'Unexpected CIM query' }
    $name = [regex]::Match($Filter, "Name = '([^']+)'").Groups[1].Value
    $features = $env:ACTIVATION_FEATURES | ConvertFrom-Json
    $property = $features.PSObject.Properties[$name]
    if ($property) { [pscustomobject]@{ Name = $name; InstallState = $property.Value } }
}
& $Script
''', encoding="utf-8-sig")
        shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.config = self.root / "chezmoi.toml"
        self.config.write_text(
            '[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
            '\nargs = ' + json.dumps(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(wrapper)]) + '\n',
            encoding="utf-8",
        )

    def apply(self, *args):
        return subprocess.run([
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--persistent-state", str(self.root / "state.boltdb"),
            "--no-tty", "apply", "--force", *args,
        ], env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)

    def assert_blocked(self, *details):
        result = self.apply()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for detail in details:
            self.assertIn(detail, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")
        self.assertFalse(self.after.exists())

    def test_enabled_features_allow_apply_without_a_distro_or_podman(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")
        self.assertTrue(self.after.exists())

    def test_disabled_absent_and_unknown_features_block_before_changes(self):
        for feature in ("VirtualMachinePlatform", "HypervisorPlatform"):
            for state in (2, 3, 4, None):
                with self.subTest(feature=feature, state=state):
                    features = {"VirtualMachinePlatform": 1, "HypervisorPlatform": 1}
                    features[feature] = state
                    self.env["ACTIVATION_FEATURES"] = json.dumps(features)
                    self.assert_blocked(feature, "manually")

    def test_missing_feature_and_failed_query_cannot_pass(self):
        self.env["ACTIVATION_FEATURES"] = json.dumps({"VirtualMachinePlatform": 1})
        self.assert_blocked("HypervisorPlatform")
        self.env["ACTIVATION_CIM_ERROR"] = "1"
        self.assert_blocked("CIM")

    def test_wsl_missing_or_nonzero_query_cannot_pass(self):
        self.env["ACTIVATION_WSL_MISSING"] = "1"
        self.assert_blocked("WSL")
        self.env["ACTIVATION_WSL_MISSING"] = "0"
        for variable in ("ACTIVATION_WSL_VERSION_EXIT", "ACTIVATION_WSL_STATUS_EXIT"):
            with self.subTest(variable=variable):
                self.env[variable] = "50"
                self.assert_blocked("WSL", "50")
                self.env[variable] = "0"

    def test_unchanged_apply_rechecks_activation(self):
        result = self.apply()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.after.unlink()
        self.env["ACTIVATION_FEATURES"] = json.dumps({"VirtualMachinePlatform": 1, "HypervisorPlatform": 2})
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HypervisorPlatform", result.stdout + result.stderr)
        self.assertFalse(self.after.exists())

    def test_dry_run_does_not_probe_or_change_state(self):
        self.env["ACTIVATION_WSL_MISSING"] = "1"
        result = self.apply("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")
        self.assertFalse(self.after.exists())


if __name__ == "__main__":
    unittest.main()
