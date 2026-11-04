import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class GitGpgSettingsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="git gpg settings ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        # Keep Git/GPG proofs offline and unable to run personal-app PATH actions.
        self.source = self.root / "source"
        shutil.copytree(self.repo / "home", self.source, ignore=shutil.ignore_patterns(
            ".chezmoiexternals", "personal-app*.json", "dot_config",
            "run_onchange_after_10-personal-app-path.*", "run_onchange_after_20-harness-plugins.*",
            "harness-plugin*.json", "private_dot_omp", "run_after_40-github-auth.*",
            "run_after_45-gitlab-auth.*",
            "run_before_05-check-windows-virtualization.ps1.tmpl",
        ))
        self.home = self.root / "user home"
        self.home.mkdir()
        self.gpg_home = self.home / ("AppData/Roaming/gnupg" if os.name == "nt" else ".gnupg")
        self.gpg_home.mkdir(parents=True)
        self.agent = self.gpg_home / "gpg-agent.conf"
        self.config = self.root / "chezmoi.toml"
        self.config.write_text(
            '[interpreters.ps1]\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n'
            if os.name == "nt" else "", encoding="utf-8",
        )
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith("GIT_CONFIG_"):
                del self.env[key]
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.home / "AppData/Roaming"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "GNUPGHOME": str(self.gpg_home),
            "GIT_CONFIG_GLOBAL": str(self.home / ".gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        if os.name == "nt":
            commands = self.root / "commands"
            commands.mkdir()
            # Full-source applies must never invoke the host's real app installer.
            (commands / "winget.cmd").write_text(
                "@echo off\nexit /b -1978335135\n", encoding="ascii",
            )
            self.env["PATH"] = str(commands) + os.pathsep + self.env["PATH"]

    def run_command(self, *args, check=True):
        result = subprocess.run(args, env=self.env, capture_output=True, text=True,
                                encoding="utf-8", errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def chezmoi(self, *args, check=True):
        return self.run_command(
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
            *args, check=check,
        )

    def test_main_default_preserves_existing_branch_and_reconciles_drift(self):
        old = self.root / "existing repository"
        self.run_command("git", "-c", "init.defaultBranch=legacy", "init", str(old))
        self.chezmoi("apply", "--force", "--exclude=scripts")
        new = self.root / "new repository"
        self.run_command("git", "init", str(new))
        self.assertEqual(self.run_command("git", "-C", str(new), "symbolic-ref", "--short", "HEAD").stdout.strip(), "main")
        self.assertEqual(self.run_command("git", "-C", str(old), "symbolic-ref", "--short", "HEAD").stdout.strip(), "legacy")
        self.run_command("git", "config", "--global", "init.defaultBranch", "local-edit")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        reconciled = self.root / "reconciled repository"
        self.run_command("git", "init", str(reconciled))
        self.assertEqual(self.run_command("git", "-C", str(reconciled), "symbolic-ref", "--short", "HEAD").stdout.strip(), "main")

    def test_pinentry_reconciliation_preserves_unrelated_state(self):
        preserved = b"# pinentry-program commented-out\r\ndefault-cache-ttl 321\r\n"
        self.agent.write_bytes(preserved + b"pinentry-program old\r\n  pinentry-program duplicate\r\nmax-cache-ttl 654")
        key_store = self.gpg_home / "private-keys-v1.d"
        key_store.mkdir()
        sentinel = key_store / "untouched.key"
        sentinel.write_bytes(b"unmanaged test sentinel")
        trust = self.gpg_home / "trustdb.gpg"
        trust.write_bytes(b"unmanaged trust sentinel")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        expected = self.agent.read_bytes()
        self.assertTrue(expected.startswith(preserved), expected)
        self.assertIn(b"max-cache-ttl 654\n", expected)
        active = [line for line in expected.splitlines() if line.lstrip().startswith(b"pinentry-program ")]
        self.assertEqual(len(active), 1, expected)
        self.assertNotIn(b" old", active[0])
        self.assertNotIn(b" duplicate", active[0])
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.agent.read_bytes(), expected)
        self.assertEqual(self.chezmoi("diff", "--exclude=scripts").stdout, "")
        self.assertEqual(sentinel.read_bytes(), b"unmanaged test sentinel")
        self.assertEqual(trust.read_bytes(), b"unmanaged trust sentinel")
        self.agent.write_bytes(expected + b"pinentry-program local-edit\n")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.agent.read_bytes(), expected)

    @unittest.skipUnless(shutil.which("gpgconf"), "GPG installation required for home detection")
    def test_custom_gpg_home_stops_before_personal_files_change(self):
        gitconfig = self.home / ".gitconfig"
        gitconfig.write_bytes(b"# existing Git settings\n")
        self.agent.write_bytes(b"# existing agent settings\n")
        self.env["GNUPGHOME"] = str(self.root / "other keyring")
        Path(self.env["GNUPGHOME"]).mkdir()
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(gitconfig.read_bytes(), b"# existing Git settings\n")
        self.assertEqual(self.agent.read_bytes(), b"# existing agent settings\n")

    @unittest.skipUnless(shutil.which("gpgconf"), "GPG installation required for home detection")
    def test_linked_gpg_home_is_preserved(self):
        self.gpg_home.rmdir()
        keyring = self.root / "existing keyring"
        keyring.mkdir()
        sentinel = keyring / "trustdb.gpg"
        sentinel.write_bytes(b"existing trust data")
        if os.name == "nt":
            self.run_command("cmd.exe", "/d", "/c", "mklink", "/J", str(self.gpg_home), str(keyring))
        else:
            self.gpg_home.symlink_to(keyring, target_is_directory=True)
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.gpg_home.is_junction() if os.name == "nt" else self.gpg_home.is_symlink())
        self.assertEqual(sentinel.read_bytes(), b"existing trust data")
        self.assertFalse((self.home / ".gitconfig").exists())

    @unittest.skipUnless(os.name == "nt" and shutil.which("gpgconf"), "Windows GPG installation required")
    def test_unicode_home_and_tool_path_under_oem_console(self):
        previous_home = self.home
        self.home = self.root / "한글 😀 home"
        previous_home.rename(self.home)
        self.gpg_home = self.home / "AppData/Roaming/gnupg"
        # GnuPG's ANSI getenv cannot transport arbitrary Unicode GNUPGHOME values.
        # Use an ASCII alias, retaining the real Unicode home and executable paths.
        gpg_alias = self.root / "ascii gpg home"
        self.run_command("cmd.exe", "/d", "/c", "mklink", "/J", str(gpg_alias), str(self.gpg_home))
        self.addCleanup(gpg_alias.rmdir)
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.home / "AppData/Roaming"),
            "GNUPGHOME": str(gpg_alias),
            "GIT_CONFIG_GLOBAL": str(self.home / ".gitconfig"),
        })
        tools = self.root / "한글 tools"
        installed = Path(shutil.which("gpgconf")).resolve().parent
        self.run_command("cmd.exe", "/d", "/c", "mklink", "/J", str(tools), str(installed))
        self.config.write_text('[data]\ngpgProgram = "' + (tools / "gpg.exe").as_posix() + '"\n', encoding="utf-8")
        self.run_command(str(installed / "gpg.exe"), "--batch", "--no-options",
                         "--no-autostart", "--list-keys")
        trust = self.gpg_home / "trustdb.gpg"
        original_trust = trust.read_bytes()
        # A temporary HOME does not isolate HKCU; execute only the GPG hook.
        args = [
            shutil.which("chezmoi"), "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty",
            "apply", "--force", "--exclude=scripts",
        ]
        reload_script = self.root / "reload-gpg-agent.ps1"
        rendered = self.chezmoi(
            "execute-template", "--file",
            str(self.repo / "home/.chezmoiscripts/run_onchange_after_10-reload-gpg-agent.ps1.tmpl"),
        ).stdout
        reload_script.write_text(rendered, encoding="utf-8")
        guard = self.root / "check-gpg-home.ps1"
        guard.write_text(self.chezmoi(
            "execute-template", "--file",
            str(self.repo / "home/.chezmoiscripts/run_before_10-check-gpg-home.ps1.tmpl"),
        ).stdout, encoding="utf-8")
        command = "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437); & " + " ".join(
            "'" + value.replace("'", "''") + "'" for value in args
        ) + "; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; & '" + str(guard).replace("'", "''") + (
            "'; if (-not $?) { exit 1 }; & '" + str(reload_script).replace("'", "''") + "'; exit $LASTEXITCODE")
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        shells = [str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]
        if shutil.which("pwsh"):
            shells.append(shutil.which("pwsh"))
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_command(shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                 "-EncodedCommand", encoded)
        self.assertEqual(self.chezmoi("diff", "--exclude=scripts").stdout, "")
        self.assertEqual(trust.read_bytes(), original_trust)

    @unittest.skipUnless(os.name == "nt" and shutil.which("gpgconf"), "Windows GPG installation required")
    def test_native_utf8_home_output_under_oem_console(self):
        installed = Path(shutil.which("gpgconf")).resolve().parent
        tools = self.root / "한글 😀 portable tools"
        tools.mkdir()
        for program in ("gpg.exe", "gpgconf.exe"):
            shutil.copy2(installed / program, tools / program)
        for library in installed.glob("*.dll"):
            shutil.copy2(library, tools / library.name)
        # An empty native control file selects portable mode without changing HKCU.
        (tools / "gpgconf.ctl").write_bytes(b"")
        portable_home = tools / "home"
        self.run_command("cmd.exe", "/d", "/c", "mklink", "/J", str(portable_home), str(self.gpg_home))
        self.addCleanup(portable_home.rmdir)
        self.run_command(str(tools / "gpg.exe"), "--batch", "--no-options",
                         "--no-autostart", "--list-keys")
        trust = self.gpg_home / "trustdb.gpg"
        original_trust = trust.read_bytes()
        self.config.write_text(
            '[data]\ngpgProgram = "' + (tools / "gpg.exe").as_posix() + '"\n', encoding="utf-8",
        )
        guard = self.root / "native-utf8-guard.ps1"
        guard.write_text(self.chezmoi(
            "execute-template", "--file",
            str(self.source / ".chezmoiscripts/run_before_10-check-gpg-home.ps1.tmpl"),
        ).stdout, encoding="utf-8")
        command = (
            "[Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437); & '"
            + str(guard).replace("'", "''") + "'; if (-not $?) { exit 1 }"
        )
        encoded = base64.b64encode(command.encode("utf-16le")).decode("ascii")
        shells = [str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]
        if shutil.which("pwsh"):
            shells.append(shutil.which("pwsh"))
        for shell in shells:
            with self.subTest(shell=shell):
                self.run_command(shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                 "-EncodedCommand", encoded)
        self.assertEqual(trust.read_bytes(), original_trust)


if __name__ == "__main__":
    unittest.main()
