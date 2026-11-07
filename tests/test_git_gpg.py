import base64
import json
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
            "run_after_45-gitlab-auth.*", "run_after_30-install-fonts.*", "private_dot_ssh",
            "run_before_05-check-windows-virtualization.ps1.tmpl",
            "private_dot_t3", "dot_local", "run_onchange_after_30-install-t3-code.sh.tmpl",
            "private_dot_gemini", "run_after_20-antigravity-plugins.*",
        ))
        sidecar = self.source / "dot_local/bin/private_dotfiles-pinentry.json.tmpl"
        sidecar.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.repo / "home/dot_local/bin/private_dotfiles-pinentry.json.tmpl", sidecar)
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

    def test_checkout_keeps_sops_dotenv_lf_despite_system_autocrlf(self):
        system = self.root / "system.gitconfig"
        system.write_text("[core]\n    autocrlf = true\n", encoding="utf-8")
        self.env.pop("GIT_CONFIG_NOSYSTEM")
        self.env["GIT_CONFIG_SYSTEM"] = str(system)
        self.chezmoi("apply", "--force", "--exclude=scripts")
        repository = self.root / "checkout"
        self.run_command("git", "init", str(repository))
        dotenv = repository / ".env.development.sops.env"
        original = b"sops_lastmodified=2026-10-14T09:28:37Z\n"
        dotenv.write_bytes(original)
        self.run_command("git", "-C", str(repository), "add", dotenv.name)
        dotenv.unlink()
        self.run_command("git", "-C", str(repository), "checkout", "--", dotenv.name)
        self.assertEqual(dotenv.read_bytes(), original)

    def test_pinentry_reconciliation_preserves_unrelated_state(self):
        preserved = b"# pinentry-program commented-out\r\n# default-cache-ttl 321\r\ndefault-cache-ttl-ssh 987\r\n"
        self.agent.write_bytes(preserved + b"pinentry-program old\r\n  pinentry-program duplicate\r\ndefault-cache-ttl 321\r\n default-cache-ttl=654\r\nmax-cache-ttl 654")
        key_store = self.gpg_home / "private-keys-v1.d"
        key_store.mkdir()
        sentinel = key_store / "untouched.key"
        sentinel.write_bytes(b"unmanaged test sentinel")
        trust = self.gpg_home / "trustdb.gpg"
        trust.write_bytes(b"unmanaged trust sentinel")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        expected = self.agent.read_bytes()
        self.assertTrue(expected.startswith(preserved), expected)
        self.assertEqual(expected.splitlines().count(b"default-cache-ttl 0"), 1)
        self.assertEqual(expected.splitlines().count(b"max-cache-ttl 0"), 1)
        self.assertNotIn(b"default-cache-ttl 321\n", expected)
        self.assertNotIn(b"default-cache-ttl=654", expected)
        self.assertNotIn(b"max-cache-ttl 654", expected)
        active = [line for line in expected.splitlines() if line.lstrip().startswith(b"pinentry-program ")]
        self.assertEqual(len(active), 1, expected)
        self.assertNotIn(b" old", active[0])
        self.assertNotIn(b" duplicate", active[0])
        self.assertIn(b"/.local/bin/dotfiles-pinentry", active[0].replace(b"\\", b"/"))
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.agent.read_bytes(), expected)
        self.assertEqual(self.chezmoi("diff", "--exclude=scripts").stdout, "")
        self.assertEqual(sentinel.read_bytes(), b"unmanaged test sentinel")
        self.assertEqual(trust.read_bytes(), b"unmanaged trust sentinel")
        self.agent.write_bytes(expected + b"pinentry-program local-edit\n")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.agent.read_bytes(), expected)

    def test_native_pinentry_override_is_retained_in_private_sidecar(self):
        fallback = "C:/custom native/pinentry.exe" if os.name == "nt" else "/custom native/pinentry"
        with self.config.open("a", encoding="utf-8") as stream:
            stream.write("\n[data]\npinentryProgram = " + json.dumps(fallback) + "\n")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        sidecar = self.home / ".local/bin/dotfiles-pinentry.json"
        self.assertTrue(sidecar.is_file())
        self.assertEqual(json.loads(sidecar.read_text(encoding="utf-8")), {"fallback": fallback})
        self.assertNotIn(fallback, self.agent.read_text(encoding="utf-8"))
        if os.name != "nt":
            self.assertEqual(sidecar.stat().st_mode & 0o777, 0o600)

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

    @unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgconf"), "Native GnuPG required")
    def test_ordinary_agent_cache_does_not_unlock_a_second_signature(self):
        gpg = shutil.which("gpg")
        gpgconf = str(Path(gpg).with_name("gpgconf.exe" if os.name == "nt" else "gpgconf"))
        scratch = tempfile.TemporaryDirectory(prefix="cpc-")
        self.addCleanup(scratch.cleanup)
        runtime = Path(scratch.name)
        profile = runtime / "h"
        profile.mkdir()
        # POSIX must avoid the default per-user socket; Windows needs short paths.
        keyring = profile / "AppData/Roaming/gnupg" if os.name == "nt" else runtime / "k"
        keyring.mkdir(parents=True, mode=0o700)
        env = self.env | {"HOME": str(profile), "USERPROFILE": str(profile),
                          "APPDATA": str(profile / "AppData/Roaming"),
                          "LOCALAPPDATA": str(runtime / "l"), "GNUPGHOME": str(keyring)}
        args = [gpg, "--no-options", "--homedir", str(keyring), "--batch", "--yes",
                "--pinentry-mode", "loopback", "--passphrase-fd", "0"]

        def invoke(arguments, passphrase):
            return subprocess.run(args + arguments, input=passphrase + b"\n", env=env,
                                  capture_output=True, timeout=60)

        def stop_agent():
            result = subprocess.run([gpgconf, "--homedir", str(keyring), "--kill", "gpg-agent"],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0)

        self.addCleanup(stop_agent)
        identity = "Pinentry cache fixture <pinentry-cache@example.invalid>"
        correct = b"synthetic-cache-fixture"
        wrong = b"incorrect-cache-fixture"
        generated = invoke(["--quick-generate-key", identity, "ed25519", "sign", "0"], correct)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        payload = self.root / "payload.txt"
        payload.write_bytes(b"isolated ordinary-agent cache proof\n")
        signing = ["--local-user", identity, "--output", str(self.root / "signature.asc"),
                   "--detach-sign", str(payload)]

        # The control proves that the second signature can use an agent cache.
        stop_agent()
        self.assertEqual(invoke(signing, correct).returncode, 0)
        self.assertEqual(invoke(signing, wrong).returncode, 0)

        self.chezmoi("apply", "--force", "--exclude=scripts")
        (keyring / "gpg-agent.conf").write_bytes(self.agent.read_bytes())
        stop_agent()
        self.assertEqual(invoke(signing, correct).returncode, 0)
        self.assertNotEqual(invoke(signing, wrong).returncode, 0)

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


@unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgconf"), "Native GnuPG required")
class GpgRecipientApplyTest(unittest.TestCase):
    run_command = GitGpgSettingsTest.run_command
    chezmoi = GitGpgSettingsTest.chezmoi

    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="gpg-import-", dir=None if os.name == "nt" else "/tmp")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / "source"
        for relative in (".chezmoidata", ".chezmoitemplates", ".chezmoiscripts"):
            (self.source / relative).mkdir(parents=True)
        for relative in (
            ".chezmoidata/gpg.yaml", ".chezmoidata/gpg-recipient.yaml",
            ".chezmoitemplates/gpg-settings", ".chezmoitemplates/gpg-home",
            ".chezmoiscripts/run_before_10-check-gpg-home.sh.tmpl",
            ".chezmoiscripts/run_before_10-check-gpg-home.ps1.tmpl",
            ".chezmoiscripts/run_before_15-import-gpg-recipient.sh.tmpl",
            ".chezmoiscripts/run_before_15-import-gpg-recipient.ps1.tmpl",
        ):
            original = self.repo / "home" / relative
            if original.exists():
                shutil.copy2(original, self.source / relative)
        self.home = self.root / "home"
        self.home.mkdir()
        self.gpg_home = self.home / ("AppData/Roaming/gnupg" if os.name == "nt" else ".gnupg")
        self.gpg_home.mkdir(parents=True, mode=0o700)
        self.config = self.root / "chezmoi.toml"
        gpg = Path(shutil.which("gpg")).resolve()
        self.config.write_text(
            '[interpreters.ps1]\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n'
            + "[data]\ngpgProgram = " + json.dumps(gpg.as_posix()) + "\n", encoding="utf-8",
        )
        self.env = os.environ | {
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.home / "AppData/Roaming"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "GNUPGHOME": str(self.gpg_home),
        }
        self.gpg = str(gpg)
        self.recipient = self.chezmoi("execute-template", "{{ .gpgRecipient }}").stdout.strip()
        self.addCleanup(self.run_command, str(gpg.with_name("gpgconf.exe" if os.name == "nt" else "gpgconf")),
                        "--kill", "gpg-agent")

    def gpg_command(self, *args, check=True):
        return self.run_command(self.gpg, "--no-options", "--batch", "--no-auto-check-trustdb", *args, check=check)

    def primary_fingerprints(self):
        lines = self.gpg_command("--with-colons", "--list-keys").stdout.splitlines()
        return [lines[index + 1].split(":")[9] for index, line in enumerate(lines) if line.startswith("pub:")]

    def ownertrust(self):
        return tuple(line for line in self.gpg_command("--export-ownertrust").stdout.splitlines()
                     if line and not line.startswith("#"))

    def generate_unrelated_key(self):
        self.gpg_command("--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
                         "Unrelated fixture <unrelated@example.invalid>", "ed25519", "sign", "0")
        return self.primary_fingerprints()[0]

    def test_explicit_apply_imports_exact_recipient_and_rerun_is_noop(self):
        self.chezmoi("apply", "--force")
        self.assertEqual(self.primary_fingerprints(), [self.recipient])
        keyring = self.gpg_home / "pubring.kbx"
        before = (keyring.read_bytes(), keyring.stat().st_mtime_ns)
        self.chezmoi("apply", "--force")
        self.assertEqual((keyring.read_bytes(), keyring.stat().st_mtime_ns), before)

    def test_import_preserves_unrelated_key_and_ownertrust(self):
        unrelated = self.generate_unrelated_key()
        trust = self.ownertrust()
        exported = self.gpg_command("--armor", "--export", unrelated).stdout
        self.chezmoi("apply", "--force")
        self.assertEqual(set(self.primary_fingerprints()), {self.recipient, unrelated})
        self.assertEqual(self.ownertrust(), trust)
        self.assertEqual(self.gpg_command("--armor", "--export", unrelated).stdout, exported)
        self.assertFalse(any(line.startswith(self.recipient + ":") for line in trust))
        keyring = self.gpg_home / "pubring.kbx"
        before = (keyring.read_bytes(), keyring.stat().st_mtime_ns)
        self.chezmoi("apply", "--force")
        self.assertEqual((keyring.read_bytes(), keyring.stat().st_mtime_ns), before)

    def test_wrong_configured_fingerprint_leaves_empty_keyring_untouched(self):
        data = self.source / ".chezmoidata/gpg.yaml"
        data.write_text(data.read_text().replace(self.recipient, "F" * 40), encoding="utf-8")
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fingerprint", result.stderr.lower())
        self.assertEqual(list(self.gpg_home.iterdir()), [])

    def test_mismatched_artifact_fails_before_keyring_mutation(self):
        unrelated = self.generate_unrelated_key()
        artifact = self.source / ".chezmoidata/gpg-recipient.yaml"
        artifact.write_text("gpgRecipientPublicKey: |\n" + "".join(
            "  " + line + "\n" for line in self.gpg_command("--armor", "--export", unrelated).stdout.splitlines()
        ), encoding="ascii")
        keyring = self.gpg_home / "pubring.kbx"
        before = keyring.read_bytes()
        trust = self.ownertrust()
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fingerprint", result.stderr.lower())
        self.assertEqual(keyring.read_bytes(), before)
        self.assertEqual(self.ownertrust(), trust)

    def test_bootstrap_and_dry_run_leave_keyring_untouched(self):
        before = list(self.gpg_home.iterdir())
        self.chezmoi("managed", "--exclude=scripts")
        self.chezmoi("apply", "--dry-run")
        self.assertEqual(list(self.gpg_home.iterdir()), before)

    def test_import_precedes_later_apply_script_and_target_rendering(self):
        # A later before-script performs real encryption; trust is scoped to this
        # fixture command because importing a public key does not confer trust.
        if os.name == "nt":
            script = ("$ErrorActionPreference = 'Stop'\n& '" + self.gpg.replace("'", "''")
                      + "' --no-options --batch --trust-model always --recipient " + self.recipient
                      + " --output '" + str(self.root / "proof.gpg").replace("'", "''")
                      + "' --encrypt '" + str(self.root / "payload").replace("'", "''")
                      + "'\nif ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n")
            extension = "ps1"
        else:
            import shlex
            script = ("#!/bin/sh\nset -eu\n" + shlex.join([
                self.gpg, "--no-options", "--batch", "--trust-model", "always", "--recipient", self.recipient,
                "--output", str(self.root / "proof.gpg"), "--encrypt", str(self.root / "payload"),
            ]) + "\n")
            extension = "sh"
        (self.root / "payload").write_bytes(b"public recipient lifecycle proof\n")
        (self.source / (".chezmoiscripts/run_before_30-prove-recipient." + extension)).write_text(script, encoding="utf-8")
        query = [self.gpg, "--no-options", "--batch", "--no-autostart", "--with-colons", "--list-keys", self.recipient]
        (self.source / "dot_recipient-ready.tmpl").write_text(
            "{{ output " + " ".join(json.dumps(value) for value in query) + " }}", encoding="utf-8",
        )
        self.chezmoi("apply", "--force")
        self.assertTrue((self.root / "proof.gpg").is_file())
        self.assertIn("fpr:::::::::" + self.recipient + ":", (self.home / ".recipient-ready").read_text())

    def test_platform_rendering_uses_selected_native_gpg(self):
        for platform in ("windows", "linux", "darwin"):
            with self.subTest(platform=platform):
                selected = "C:/native tools/gpg.exe" if platform == "windows" else "/native tools/gpg"
                extension = "ps1" if platform == "windows" else "sh"
                override = json.dumps({"chezmoi": {"os": platform}, "gpgProgram": selected})
                script = self.chezmoi("--override-data", override, "execute-template", "--file",
                                      str(self.source / (".chezmoiscripts/run_before_15-import-gpg-recipient." + extension + ".tmpl"))).stdout
                self.assertIn(selected, script)
                self.assertNotIn("--trust-model", script)
                self.assertNotIn("--import-ownertrust", script)


if __name__ == "__main__":
    unittest.main()
