import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows PowerShell prerequisite check")
class Wsl2PreflightTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        scratch = tempfile.TemporaryDirectory(prefix="wsl prerequisites ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.script = self.root / "한글 checkout" / "check-wsl2.ps1"
        self.script.parent.mkdir()
        shutil.copy2(self.repo / "scripts/check-wsl2.ps1", self.script)
        self.sentinel = self.root / "personal state.txt"
        self.sentinel.write_text("unchanged", encoding="utf-8")

    @staticmethod
    def quote(value):
        return "'" + str(value).replace("'", "''") + "'"

    def probe(self, *, wsl_exit=0, version_exit=0, wsl_missing=False, feature_state="1",
              hypervisor="$true", feature_error=False, computer_error=False,
              feature_absent=False, computer_absent=False, diagnostic_stderr=False,
              diagnostic="Aucune distribution installee. Version par defaut : 1."):
        calls = self.root / "wsl calls.txt"
        mutations = self.root / "mutations.txt"
        result_file = self.root / "result.json"
        native = self.root / "wsl.cmd"
        native.write_text(
            '@echo off\n'
            f'echo %*>>"{calls}"\n'
            'if not "%~2"=="" exit /b 92\n'
            'if "%~1"=="--version" (\n'
            '  echo WSL-Version : 2.6.1\n'
            f'  exit /b {version_exit}\n'
            ')\n'
            'if not "%~1"=="--status" exit /b 91\n'
            f'echo {diagnostic}' + (' 1>&2\n' if diagnostic_stderr else '\n') +
            f'exit /b {wsl_exit}\n', encoding="ascii",
        )
        command = (
            "$ErrorActionPreference = 'Stop'\n"
            "[Console]::OutputEncoding = New-Object Text.UTF8Encoding\n"
            "function Get-Command {\n"
            "  [CmdletBinding()] param([string] $Name, [string[]] $CommandType)\n"
            "  if ($Name -ne 'wsl.exe') { throw ('Unexpected command lookup: ' + $Name) }\n"
            + ("  throw 'Command not found'\n" if wsl_missing else
               "  Microsoft.PowerShell.Core\\Get-Command -Name " + self.quote(native) +
               " -CommandType Application -ErrorAction Stop\n") +
            "}\n"
            "function Get-CimInstance {\n"
            "  [CmdletBinding()] param([string] $ClassName, [string] $Filter)\n"
            "  switch ($ClassName) {\n"
            "    'Win32_OptionalFeature' {\n"
            "      if ($Filter -ne \"Name = 'VirtualMachinePlatform'\") { throw 'Unexpected feature query' }\n"
            + ("      throw 'CIM feature access denied'\n" if feature_error else
               "      return\n" if feature_absent else
               f"      [pscustomobject]@{{ InstallState = {feature_state} }}\n") +
            "    }\n"
            "    'Win32_ComputerSystem' {\n"
            + ("      throw 'CIM computer access denied'\n" if computer_error else
               "      return\n" if computer_absent else
               f"      [pscustomobject]@{{ HypervisorPresent = {hypervisor} }}\n") +
            "    }\n"
            "    default { throw ('Unexpected CIM query: ' + $ClassName) }\n"
            "  }\n"
            "}\n"
            "$mutationLog = " + self.quote(mutations) + "\n"
            "foreach ($name in @('Enable-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature',\n"
            "    'Set-WindowsOptionalFeature', 'Restart-Computer', 'Start-Process',\n"
            "    'Invoke-CimMethod', 'Set-CimInstance', 'Remove-CimInstance')) {\n"
            "  Set-Item -Path ('Function:' + $name) -Value {\n"
            "    [IO.File]::AppendAllText($mutationLog, 'mutation attempted')\n"
            "    throw 'OS mutation forbidden in prerequisite check'\n"
            "  }\n"
            "}\n"
            "try {\n"
            "  & " + self.quote(self.script) + "\n"
            "  $result = @{ outcome = 'allowed'; message = ''; callerContinued = $true }\n"
            "} catch {\n"
            "  $result = @{ outcome = 'rejected'; message = $_.Exception.Message; callerContinued = $true }\n"
            "}\n"
            "[IO.File]::WriteAllText(" + self.quote(result_file) + ", ($result | ConvertTo-Json))\n"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        result = subprocess.run(
            [str(self.shell), "-NoLogo", "-NoProfile", "-NonInteractive",
             "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            cwd=self.root, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result_file.exists(), "Check must return or throw, not exit its caller: " +
                        result.stdout + result.stderr)
        observation = json.loads(result_file.read_text(encoding="utf-8-sig"))
        self.assertTrue(observation["callerContinued"])
        self.assertFalse(mutations.exists(), "Check attempted an OS mutation")
        self.assertEqual(self.sentinel.read_text(encoding="utf-8"), "unchanged")
        if not wsl_missing:
            expected = ["--version"] if version_exit else ["--version", "--status"]
            self.assertEqual(calls.read_text(encoding="ascii").splitlines(), expected)
        return observation, result.stdout + result.stderr

    def assert_rejected(self, observation, *details):
        self.assertEqual(observation["outcome"], "rejected", observation)
        for detail in details:
            self.assertIn(detail, observation["message"])

    def test_ready_host_without_distro_or_wsl1_feature_returns_to_caller(self):
        observation, output = self.probe()
        self.assertEqual(observation["outcome"], "allowed", observation)

    def test_missing_wsl_command_is_actionable_and_does_not_exit_caller(self):
        observation, _ = self.probe(wsl_missing=True)
        self.assert_rejected(observation, "WSL", "install")

    def test_native_failure_is_rejected_without_parsing_localized_diagnostics(self):
        observation, _ = self.probe(
            wsl_exit=50, diagnostic="Le composant doit etre active.", diagnostic_stderr=True,
        )
        self.assert_rejected(observation, "WSL", "50", "restart")

    def test_inbox_command_without_modern_wsl_runtime_is_rejected(self):
        observation, _ = self.probe(version_exit=87)
        self.assert_rejected(observation, "WSL", "--version", "87", "install")

    def test_native_success_does_not_depend_on_english_status_text(self):
        observation, _ = self.probe(diagnostic="Keine Distribution installiert.")
        self.assertEqual(observation["outcome"], "allowed", observation)

    def test_successful_native_stderr_is_not_itself_a_failure(self):
        observation, _ = self.probe(diagnostic_stderr=True)
        self.assertEqual(observation["outcome"], "allowed", observation)

    def test_disabled_removed_or_unknown_virtual_machine_platform_is_rejected(self):
        for state in ("2", "3", "4", "0", "$null", "'Enabled'"):
            with self.subTest(state=state):
                observation, _ = self.probe(feature_state=state)
                self.assert_rejected(observation, "Virtual Machine Platform", "enable")
                # Each observation runs in a fresh PowerShell process, not a changed host.
                (self.root / "wsl calls.txt").unlink()

    def test_feature_query_failure_is_not_treated_as_enabled(self):
        observation, _ = self.probe(feature_error=True)
        self.assert_rejected(observation, "Virtual Machine Platform", "CIM feature access denied")

    def test_missing_feature_evidence_is_rejected(self):
        observation, _ = self.probe(feature_absent=True)
        self.assert_rejected(observation, "Virtual Machine Platform")

    def test_absent_or_unknown_running_hypervisor_is_rejected(self):
        for present in ("$false", "$null", "'unknown'", "'True'"):
            with self.subTest(present=present):
                observation, _ = self.probe(hypervisor=present)
                self.assert_rejected(observation, "hypervisor", "restart")
                (self.root / "wsl calls.txt").unlink()

    def test_computer_query_failure_is_not_treated_as_ready(self):
        observation, _ = self.probe(computer_error=True)
        self.assert_rejected(observation, "hypervisor", "CIM computer access denied")

    def test_missing_computer_evidence_is_rejected(self):
        observation, _ = self.probe(computer_absent=True)
        self.assert_rejected(observation, "hypervisor")


if __name__ == "__main__":
    unittest.main()
