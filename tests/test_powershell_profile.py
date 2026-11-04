import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


def available_shells():
    shells = []
    if shutil.which("pwsh"):
        shells.append(shutil.which("pwsh"))
    if os.name == "nt":
        legacy = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        if legacy.is_file():
            shells.append(str(legacy))
    return shells


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(shutil.which("chezmoi") and shutil.which("mise") and available_shells(),
                     "Real chezmoi, mise, and PowerShell required")
class PowerShellProfileTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="powershell profile ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        (self.project / "mise.toml").write_text(
            "[env]\nDOTFILES_PROFILE_PROBE = 'activated'\n", encoding="utf-8")
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.upper().startswith(("__MISE_", "DOTFILES_PROFILE_")) or key.upper() == "MISE_SHELL":
                del self.env[key]
        self.env.update({
            "MISE_CONFIG_DIR": str(self.root / "mise config"),
            "MISE_TRUSTED_CONFIG_PATHS": str(self.project),
            "MISE_AUTO_INSTALL": "false",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
        })
        self.install_script = self.root / "install.ps1"
        self.install_script.write_text(self.render("powershell-mise-profile-install"), encoding="utf-8-sig")

    def run_command(self, *args, check=True):
        result = subprocess.run(args, cwd=self.project, env=self.env,
                                capture_output=True, text=True, encoding="utf-8",
                                errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def render(self, name):
        return self.run_command(
            "chezmoi", "--source", str(self.repo), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
            "execute-template", '{{ includeTemplate "' + name + '" . }}',
        ).stdout

    def powershell(self, shell, command, check=True, profiles=False):
        command = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); " + command
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        options = [] if profiles else ["-NoProfile"]
        return self.run_command(shell, "-NoLogo", *options, "-NonInteractive",
                                "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded,
                                check=check)

    def install(self, shell, target, check=True):
        # Redirect the automatic variable in this child only. Windows Known Folders
        # ignore a temporary HOME and must never be used for test writes.
        command = ("$ErrorActionPreference = 'Stop'; "
                   "$PROFILE = 'disposable-host-profile' | "
                   "Add-Member -NotePropertyName CurrentUserAllHosts -PassThru "
                   "-NotePropertyValue " + quote(target) + "; "
                   "& " + quote(self.install_script))
        return self.powershell(shell, command, check=check)

    def probe(self, shell, target=None, profiles=False):
        load = ". " + quote(target) + "; " if target else ""
        command = ("$ErrorActionPreference = 'Stop'; " + load +
                   "prompt | Out-Null; "
                   "$result = @{ value = $env:DOTFILES_PROFILE_PROBE; "
                   "old = $env:DOTFILES_PROFILE_OLD; shell = $env:MISE_SHELL; "
                   "command = [string](Get-Command mise).CommandType }; "
                   "'PROFILE_RESULT=' + ($result | ConvertTo-Json -Compress)")
        result = self.powershell(shell, command, profiles=profiles)
        line = next(line for line in result.stdout.splitlines() if line.startswith("PROFILE_RESULT="))
        self.assertEqual(json.loads(line.split("=", 1)[1]), {
            "value": "activated", "old": None, "shell": "pwsh", "command": "Function",
        })

    def test_missing_profile_activates_real_mise_in_each_runtime(self):
        for index, shell in enumerate(available_shells()):
            with self.subTest(shell=shell):
                target = self.home / ("profile " + str(index)) / "설정" / "profile.ps1"
                self.install(shell, target)
                self.probe(shell, target)

    def test_existing_profile_is_replaced_and_local_edits_are_repaired(self):
        for index, shell in enumerate(available_shells()):
            with self.subTest(shell=shell):
                directory = self.home / ("existing " + str(index))
                directory.mkdir()
                target = directory / "profile.ps1"
                sibling = directory / "Microsoft.PowerShell_profile.ps1"
                sibling.write_bytes(b"# host-specific sentinel\r\n")
                for _ in range(2):
                    target.write_text("$env:DOTFILES_PROFILE_OLD = 'local'\n", encoding="utf-8-sig")
                    self.install(shell, target)
                    self.install(shell, target)
                    self.probe(shell, target)
                    self.assertEqual(sibling.read_bytes(), b"# host-specific sentinel\r\n")

    def test_write_failure_is_not_reported_as_success(self):
        target = self.home / "directory-not-a-file"
        target.mkdir()
        for shell in available_shells():
            with self.subTest(shell=shell):
                result = self.install(shell, target, check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(target.is_dir())

    @unittest.skipIf(os.name == "nt" and not (
        os.environ.get("GITHUB_ACTIONS") == "true" and
        os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    ), "Normal Windows startup writes require a disposable GitHub-hosted runner")
    def test_normal_startup_loads_installed_profile(self):
        if os.name != "nt":
            self.env["HOME"] = str(self.home)
        for shell in available_shells():
            with self.subTest(shell=shell):
                path = self.powershell(shell, "$PROFILE.CurrentUserAllHosts").stdout.strip()
                target = Path(path)
                if os.name != "nt":
                    self.assertTrue(target.is_relative_to(self.home), path)
                previous = target.read_bytes() if target.is_file() else None
                try:
                    self.powershell(shell, "& " + quote(self.install_script))
                    self.probe(shell, profiles=True)
                    control = self.powershell(shell, "[string]$env:MISE_SHELL")
                    self.assertEqual(control.stdout.strip(), "")
                finally:
                    if previous is None:
                        target.unlink(missing_ok=True)
                    else:
                        target.write_bytes(previous)


if __name__ == "__main__":
    unittest.main()
