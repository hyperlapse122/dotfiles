import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows PowerShell entry point")
class WindowsBootstrapTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.git = shutil.which("git")
        self.assertIsNotNone(self.git, "Install Git before running bootstrap tests")
        self.assertIsNotNone(shutil.which("mise"), "Install mise before running bootstrap tests")
        self.scratch = tempfile.TemporaryDirectory(prefix="windows bootstrap ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.checkout = self.root / "checkout with spaces"
        self.checkout.mkdir()
        self.env = os.environ.copy()
        self.env["MISE_CONFIG_DIR"] = str(self.root / "mise config")
        self.commands = self.root / "commands"
        self.commands.mkdir()
        (self.commands / "chezmoi.cmd").write_text("@echo off\nexit /b 0\n", encoding="ascii")
        self.native_candidates = [self.commands / "chezmoi.cmd"]
        # Never let this regression suite install packages on the host.
        (self.commands / "winget.cmd").write_text("@echo off\nexit /b 89\n", encoding="ascii")
        self.env["PATH"] = str(self.commands) + os.pathsep + self.env["PATH"]
        self.git_run("init", str(self.checkout))
        self.git_run("-C", str(self.checkout), "remote", "add", "origin", "https://github.com/hyperlapse122/dotfiles.git")
        for name in ("mise.toml", "mise.lock", ".chezmoiroot", ".chezmoi-bootstrap.toml"):
            shutil.copy2(self.repo / name, self.checkout / name)
        shutil.copytree(self.repo / ".mise", self.checkout / ".mise")
        shutil.copytree(self.repo / "home", self.checkout / "home")

    def git_run(self, *args):
        return subprocess.run([self.git, *args], check=True, capture_output=True, text=True)

    def run_bootstrap(self, destination=None):
        candidates = ", ".join("'" + str(p).replace("'", "''") + "'" for p in self.native_candidates)
        script = str(self.repo / "bootstrap.ps1").replace("'", "''")
        target = str(destination or self.checkout).replace("'", "''")
        launcher = (
            "function Get-Command { [CmdletBinding()] param([string[]] $Name, "
            "[switch] $All, [string[]] $CommandType); "
            f"if ($Name.Count -eq 1 -and $Name[0] -eq 'chezmoi') {{ $PSBoundParameters['Name'] = @({candidates}) }}; "
            "Microsoft.PowerShell.Core\\Get-Command @PSBoundParameters }; "
            f"& '{script}' -Destination '{target}'"
        )
        encoded = base64.b64encode(launcher.encode("utf-16le")).decode("ascii")
        return subprocess.run(
            [str(self.shell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=120,
        )

    def failing_mise(self, body):
        (self.commands / "mise.cmd").write_text("@echo off\n" + body + "\n", encoding="ascii")

    def test_repeat_preserves_uncommitted_checkout_files(self):
        sentinel = self.checkout / "local setting.txt"
        sentinel.write_text("keep this local edit", encoding="utf-8")
        for _ in range(2):
            result = self.run_bootstrap()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep this local edit")
            origin = self.git_run("-C", str(self.checkout), "remote", "get-url", "origin").stdout.strip()
            self.assertEqual(origin, "https://github.com/hyperlapse122/dotfiles.git")

    def test_unicode_checkout_with_oem_console_encoding(self):
        destination = self.root / "한글 checkout"
        self.checkout.rename(destination)
        sentinel = destination / "local setting.txt"
        sentinel.write_text("keep Unicode checkout", encoding="utf-8")
        script_path = str(self.repo / "bootstrap.ps1").replace("'", "''")
        destination_path = str(destination).replace("'", "''")
        command = (
            "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437); "
            f"& '{script_path}' -Destination '{destination_path}'"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        result = subprocess.run(
            [str(self.shell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
            env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep Unicode checkout")

    def test_unrelated_directory_is_untouched(self):
        destination = self.root / "unrelated"
        destination.mkdir()
        sentinel = destination / "important.txt"
        sentinel.write_text("not a checkout", encoding="utf-8")
        result = self.run_bootstrap(destination)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "not a checkout")
        self.assertFalse((destination / ".git").exists())

    def test_nested_directory_is_not_mistaken_for_repository_root(self):
        nested = self.checkout / "nested"
        nested.mkdir()
        sentinel = nested / "important.txt"
        sentinel.write_text("preserve nested content", encoding="utf-8")
        result = self.run_bootstrap(nested)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve nested content")
        self.assertFalse((nested / ".git").exists())

    def test_wrong_origin_is_not_prepared(self):
        self.git_run("-C", str(self.checkout), "remote", "set-url", "origin", "https://example.com/other.git")
        sentinel = self.checkout / "important.txt"
        sentinel.write_text("not our repository", encoding="utf-8")
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "not our repository")
        origin = self.git_run("-C", str(self.checkout), "remote", "get-url", "origin").stdout.strip()
        self.assertEqual(origin, "https://example.com/other.git")

    def test_mise_copy_does_not_satisfy_native_installation(self):
        (self.commands / "chezmoi.cmd").unlink()
        self.failing_mise("exit /b 0")
        cases = (
            ("MISE_DATA_DIR", self.root / "relocated mise", "shims"),
            ("MISE_SHIMS_DIR", self.root / "custom shims", ""),
            ("XDG_DATA_HOME", self.root / "xdg data", "mise/shims"),
            ("MISE_INSTALL_STORE_DIR", self.root / "custom store", "chezmoi"),
        )
        for key, root, suffix in cases:
            with self.subTest(key=key):
                directory = root / suffix
                directory.mkdir(parents=True)
                shim = directory / "chezmoi.cmd"
                shim.write_text("@echo off\nexit /b 0\n", encoding="ascii")
                self.native_candidates = [shim]
                self.env[key] = root.as_posix()
                result = self.run_bootstrap()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                del self.env[key]


    def test_install_failure_cannot_report_completion(self):
        self.failing_mise('if "%1"=="install" exit /b 17\nexit /b 0')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_postinstall_check_cannot_report_completion(self):
        self.failing_mise('if "%1"=="run" exit /b 23\nexit /b 0')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
