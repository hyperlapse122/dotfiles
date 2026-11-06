import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

if os.name == "nt":
    import winreg


REPO = Path(__file__).resolve().parents[1]
POWERSHELL = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"


@unittest.skipUnless(os.name == "nt", "Windows long path support")
class WindowsLongPathsTest(unittest.TestCase):
    def setUp(self):
        # A disposable HKCU key stands in for HKLM so tests never change machine policy.
        self.subkey = "Software\\dotfiles-long-paths-test-" + uuid.uuid4().hex
        winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.subkey).Close()
        self.addCleanup(winreg.DeleteKey, winreg.HKEY_CURRENT_USER, self.subkey)
        self.registry_path = "HKCU:\\" + self.subkey

    def run_script(self, script=REPO / "scripts/windows-long-paths.ps1"):
        result = subprocess.run(
            [str(POWERSHELL), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
             str(script), "-RegistryPath", self.registry_path, "-NoElevation"],
            capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def value(self):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey) as key:
            return winreg.QueryValueEx(key, "LongPathsEnabled")

    def set_value(self, value):
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.subkey, 0, winreg.KEY_SET_VALUE) as key:
            winreg.SetValueEx(key, "LongPathsEnabled", 0, winreg.REG_DWORD, value)

    def test_missing_value_is_enabled(self):
        self.assertIn("Enabled Windows long path support", self.run_script())
        self.assertEqual(self.value(), (1, winreg.REG_DWORD))

    def test_disabled_value_is_enabled(self):
        self.set_value(0)
        self.run_script()
        self.assertEqual(self.value(), (1, winreg.REG_DWORD))

    def test_enabled_value_is_left_untouched(self):
        self.set_value(1)
        self.assertEqual(self.run_script().strip(), "")
        self.assertEqual(self.value(), (1, winreg.REG_DWORD))

    def test_chezmoi_script_invokes_worktree_script(self):
        chezmoi = shutil.which("chezmoi")
        if not chezmoi:
            self.skipTest("chezmoi is required to render the launcher")
        template = (REPO / "home/.chezmoiscripts/run_before_03-windows-long-paths.ps1.tmpl").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory(prefix="long paths ' ") as scratch:
            config = Path(scratch) / "chezmoi.toml"
            config.write_text("", encoding="utf-8")
            rendered = subprocess.run(
                [chezmoi, "--config", str(config), "--source", str(REPO / "home"),
                 "--working-tree", str(REPO), "execute-template", template],
                capture_output=True, text=True, encoding="utf-8", timeout=60, check=True).stdout
        self.assertIn("scripts/windows-long-paths.ps1'", rendered.replace("\\", "/"))


if __name__ == "__main__":
    unittest.main()
