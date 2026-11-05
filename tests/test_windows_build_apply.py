import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


HOOK = "run_after_25-windows-build-environment.ps1.tmpl"
WINDOWS_X64 = os.name == "nt" and platform.machine().lower() in ("amd64", "x86_64")


@unittest.skipUnless(shutil.which("chezmoi"), "Real chezmoi required")
class WindowsBuildApplyTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="windows build apply ")
        self.addCleanup(scratch.cleanup)
        # Match native working-directory receipts even when TEMP uses an 8.3 alias.
        self.root = Path(scratch.name).resolve()
        self.worktree = self.root / "active 한글 worktree's source"
        self.source = self.worktree / "home"
        scripts = self.source / ".chezmoiscripts"
        scripts.mkdir(parents=True)
        shutil.copy2(self.repo / "home/.chezmoiscripts" / HOOK, scripts / HOOK)
        templates = self.source / ".chezmoitemplates"
        templates.mkdir()
        shutil.copy2(scripts / HOOK, templates / "build-hook")
        (self.worktree / ".chezmoiroot").write_text("home\n", encoding="utf-8")
        self.home = self.root / "destination"
        self.home.mkdir()
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "MISE_CONFIG_DIR": str(self.root / "mise config"),
            "MISE_TRUSTED_CONFIG_PATHS": str(self.worktree),
            "MISE_AUTO_INSTALL": "false",
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
        })
        self.env.pop("MISE_ENV", None)
        self.env.pop("MISE_CONFIG_FILE", None)

    def chezmoi(self, *args, check=True):
        result = subprocess.run([
            "chezmoi", "--source", str(self.worktree), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "chezmoi.boltdb"), "--no-tty", *args,
        ], cwd=self.root, env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def render(self, operating_system, architecture):
        context = ("{{ $data := dict \"chezmoi\" (dict \"os\" " + json.dumps(operating_system) +
                   " \"arch\" " + json.dumps(architecture) + " \"workingTree\" " +
                   json.dumps(str(self.worktree), ensure_ascii=False) + ") }}" +
                   '{{ includeTemplate "build-hook" $data }}')
        return self.chezmoi("execute-template", context).stdout

    def test_only_windows_x64_renders_a_native_bom_script(self):
        self.assertTrue(self.render("windows", "amd64").startswith("\ufeff"))
        for operating_system, architecture in (("linux", "amd64"), ("darwin", "arm64"),
                                                ("darwin", "amd64"), ("windows", "arm64")):
            with self.subTest(os=operating_system, arch=architecture):
                self.assertEqual(self.render(operating_system, architecture).strip(), "")

    def prepare_lifecycle(self):
        self.assertIsNotNone(shutil.which("mise"), "Real mise required")
        shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.config.write_text(
            '[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
            '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n',
            encoding="utf-8")
        # The real task runner executes a disposable action, never a host installer.
        (self.worktree / "mise.toml").write_text(
            '[tasks.windows-build]\nshell = "powershell -NoProfile -ExecutionPolicy Bypass -Command"\n'
            'run = "& ./build-action.ps1"\n', encoding="utf-8")
        (self.worktree / "build-action.ps1").write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "if ($env:BUILD_APPLY_FAIL -eq '1') { throw 'Disposable provisioning failed' }\n"
            "[IO.File]::AppendAllText($env:BUILD_APPLY_RECEIPT, $PWD.Path + [Environment]::NewLine)\n",
            encoding="utf-8-sig")
        self.receipt = self.root / "applied.txt"
        self.after = self.root / "after.txt"
        self.env["BUILD_APPLY_RECEIPT"] = str(self.receipt)
        self.env["BUILD_APPLY_AFTER"] = str(self.after)
        self.env.pop("BUILD_APPLY_FAIL", None)
        (self.source / ".chezmoiscripts/run_after_99-completion.ps1").write_text(
            "[IO.File]::WriteAllText($env:BUILD_APPLY_AFTER, 'complete')\n", encoding="utf-8")
        # CWD has a conflicting task: only the hook's absolute --cd can select the source.
        (self.root / "mise.toml").write_text(
            '[tasks.windows-build]\nrun = "exit 97"\n', encoding="utf-8")

    @unittest.skipUnless(WINDOWS_X64, "Windows x64 apply lifecycle")
    def test_every_explicit_apply_runs_current_worktree_task(self):
        self.prepare_lifecycle()
        for count in (1, 2):
            self.chezmoi("apply")
            self.assertEqual(self.receipt.read_text(encoding="utf-8").splitlines(),
                             [str(self.worktree)] * count)
            self.assertEqual(self.after.read_text(encoding="utf-8"), "complete")

    @unittest.skipUnless(WINDOWS_X64, "Windows x64 apply lifecycle")
    def test_dry_run_and_script_exclusion_do_not_provision(self):
        self.prepare_lifecycle()
        self.chezmoi("apply", "--dry-run")
        self.chezmoi("apply", "--exclude=scripts")
        self.chezmoi("managed", "--exclude=scripts")
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.after.exists())

    @unittest.skipUnless(WINDOWS_X64, "Windows x64 apply lifecycle")
    def test_task_failure_stops_apply_before_completion(self):
        self.prepare_lifecycle()
        self.env["BUILD_APPLY_FAIL"] = "1"
        result = self.chezmoi("apply", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Disposable provisioning failed", result.stdout + result.stderr)
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.after.exists())
        del self.env["BUILD_APPLY_FAIL"]
        self.chezmoi("apply")
        self.assertEqual(self.receipt.read_text(encoding="utf-8").splitlines(),
                         [str(self.worktree)])
        self.assertEqual(self.after.read_text(encoding="utf-8"), "complete")


if __name__ == "__main__":
    unittest.main()
