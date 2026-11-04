import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows host application installation")
class WindowsAppsTest(unittest.TestCase):
    packages = ("Google.Chrome", "AgileBits.1Password", "AgileBits.1Password.CLI", "Microsoft.PowerShell")

    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="windows apps ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        # Use just the app source state: Git/GPG prerequisites are tested separately.
        for relative in (".chezmoidata/windows.yaml", ".chezmoiscripts/run_onchange_before_20-install-windows-apps.ps1.tmpl"):
            source = self.repo / "home" / relative
            if source.exists():
                target = self.source / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.config = self.root / "chezmoi.toml"
        # Hide pwsh and real WinGet: first application must work with Windows PowerShell.
        shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.config.write_text(
            '[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
            '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n',
            encoding="utf-8",
        )
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text("{}", encoding="utf-8")
        self.invocations = self.root / "invocations.txt"
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi)
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            # An absent or broken command double cannot reach the real host WinGet.
            "PATH": str(self.commands),
            "APP_TEST_INVENTORY": str(self.inventory),
            "APP_TEST_INVOCATIONS": str(self.invocations),
        })
        self.env.pop("APP_TEST_FAIL_PACKAGE", None)
        fake = self.root / "winget.py"
        fake.write_text('''import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["APP_TEST_INVOCATIONS"]).open("a", encoding="utf-8") as log:
    log.write("invoked\\n")
if not args or args[0] != "install" or "--id" not in args:
    sys.exit(87)
package = args[args.index("--id") + 1]
if "--exact" not in args or "--source" not in args or args[args.index("--source") + 1] != "winget":
    sys.exit(87)
if package == os.environ.get("APP_TEST_FAIL_PACKAGE"):
    print("Simulated package installation failure", file=sys.stderr)
    sys.exit(23)
path = Path(os.environ["APP_TEST_INVENTORY"])
inventory = json.loads(path.read_text(encoding="utf-8"))
if package in inventory and "--no-upgrade" in args:
    sys.exit(0x8A150061 - 2**32)
inventory[package] = "2.0"
path.write_text(json.dumps(inventory), encoding="utf-8")
''', encoding="utf-8")
        (self.commands / "winget.cmd").write_text(
            f'@echo off\n"{sys.executable}" "{fake}" %*\nexit /b %errorlevel%\n', encoding="utf-8",
        )

    def apply(self, *args, check=True):
        result = subprocess.run([
            self.chezmoi, "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
            "apply", *args,
        ], env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def installed(self):
        return json.loads(self.inventory.read_text(encoding="utf-8"))

    def test_existing_version_survives_and_unchanged_apply_skips_installer(self):
        self.inventory.write_text(json.dumps({self.packages[0]: "1.0"}), encoding="utf-8")
        expected = dict(zip(self.packages, ("1.0", "2.0", "2.0", "2.0")))
        self.apply()
        self.assertEqual(self.installed(), expected)
        calls = self.invocations.read_text(encoding="utf-8")
        self.apply()
        self.assertEqual(self.installed(), expected)
        self.assertEqual(self.invocations.read_text(encoding="utf-8"), calls)
        removed = self.installed()
        del removed[self.packages[2]]
        self.inventory.write_text(json.dumps(removed), encoding="utf-8")
        self.apply()
        self.assertEqual(self.installed(), removed)
        self.assertEqual(self.invocations.read_text(encoding="utf-8"), calls)

    def test_failed_install_preserves_progress_and_can_complete_on_rerun(self):
        self.env["APP_TEST_FAIL_PACKAGE"] = self.packages[1]
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.packages[1], result.stdout + result.stderr)
        self.assertEqual(self.installed(), {self.packages[0]: "2.0"})
        del self.env["APP_TEST_FAIL_PACKAGE"]
        self.apply()
        self.assertEqual(self.installed(), dict.fromkeys(self.packages, "2.0"))

    def test_last_package_failure_is_not_hidden(self):
        self.env["APP_TEST_FAIL_PACKAGE"] = self.packages[-1]
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.packages[-1], result.stdout + result.stderr)
        self.assertEqual(self.installed(), dict.fromkeys(self.packages[:-1], "2.0"))

    def test_dry_run_does_not_execute_installer(self):
        self.apply("--dry-run")
        self.assertFalse(self.invocations.exists())
        self.assertEqual(self.installed(), {})

    def test_missing_winget_reports_prerequisite(self):
        (self.commands / "winget.cmd").unlink()
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App Installer", result.stdout + result.stderr)
        self.assertEqual(self.installed(), {})

    def test_package_data_change_runs_installer_again(self):
        self.apply()
        added = "Example.NewApp"
        with (self.source / ".chezmoidata/windows.yaml").open("a", encoding="utf-8") as data:
            data.write(f"    - {added}\n")
        self.apply()
        self.assertEqual(self.installed(), dict.fromkeys((*self.packages, added), "2.0"))

    def test_data_formatting_and_unrelated_values_do_not_run_installer(self):
        self.apply()
        calls = self.invocations.read_text(encoding="utf-8")
        data = self.source / ".chezmoidata/windows.yaml"
        data.write_text("# formatting only\n" + data.read_text(encoding="utf-8") +
                        "\nunrelated: changed\n", encoding="utf-8")
        self.apply()
        self.assertEqual(self.invocations.read_text(encoding="utf-8"), calls)


if __name__ == "__main__":
    unittest.main()
