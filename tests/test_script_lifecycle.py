import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("chezmoi") and shutil.which("gpgconf"), "Chezmoi and GPG required")
class ScriptLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="script lifecycle ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for directory in (".chezmoidata", ".chezmoitemplates", "private_dot_gnupg", "AppData"):
            shutil.copytree(self.repo / "home" / directory, self.source / directory)
        shutil.copy2(self.repo / "home/.chezmoiignore", self.source / ".chezmoiignore")
        sidecar = self.source / "dot_local/bin/private_dotfiles-pinentry.json.tmpl"
        sidecar.parent.mkdir(parents=True)
        shutil.copy2(self.repo / "home/dot_local/bin/private_dotfiles-pinentry.json.tmpl", sidecar)
        scripts = self.source / ".chezmoiscripts"
        scripts.mkdir()
        # Deliberately omit app/registry scripts: temporary HOME does not isolate HKCU.
        for script in (self.repo / "home/.chezmoiscripts").iterdir():
            if "gpg" in script.name:
                shutil.copy2(script, scripts / script.name)
        self.gpg_home = self.home / ("AppData/Roaming/gnupg" if os.name == "nt" else ".gnupg")
        self.gpg_home.mkdir(parents=True)
        self.env = os.environ.copy()
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
        })
        self.config = self.root / "chezmoi.toml"
        gpgconf = Path(shutil.which("gpgconf")).resolve()
        self.program = gpgconf.with_name("gpg.exe" if os.name == "nt" else "gpg")
        self.configure()

    def configure(self, program=None, pinentry=None):
        text = ""
        if os.name == "nt":
            shell = shutil.which("pwsh") or str(
                Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            text += ('[interpreters.ps1]\ncommand = ' + json.dumps(shell) +
                     '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        text += "[data]\ngpgProgram = " + json.dumps(str(program or self.program)) + "\n"
        if pinentry:
            text += "pinentryProgram = " + json.dumps(pinentry) + "\n"
        self.config.write_text(text, encoding="utf-8")

    def chezmoi(self, *arguments, check=True):
        result = subprocess.run([
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", *arguments,
        ], env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def reload_pending(self):
        status = self.chezmoi("status").stdout
        return any("reload-gpg-agent" in line for line in status.splitlines())

    def test_unchanged_apply_skips_reload_but_keeps_guard(self):
        self.chezmoi("apply", "--force")
        self.assertFalse(self.reload_pending())
        self.chezmoi("apply", "--force")
        self.assertFalse(self.reload_pending())
        self.assertFalse((self.home / ".chezmoiscripts").exists())
        sentinel = self.gpg_home / "gpg-agent.conf"
        before = sentinel.read_bytes()
        self.env["GNUPGHOME"] = str(self.root / "different keyring")
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GPG uses", result.stdout + result.stderr)
        self.assertEqual(sentinel.read_bytes(), before)

    def test_effective_pinentry_change_schedules_reload(self):
        self.chezmoi("apply", "--force")
        self.configure(pinentry="C:/changed pinentry.exe" if os.name == "nt" else "/changed/pinentry")
        self.assertTrue(self.reload_pending())
        self.chezmoi("apply", "--force")
        self.assertFalse(self.reload_pending())
        self.assertIn("dotfiles-pinentry", (self.gpg_home / "gpg-agent.conf").read_text(encoding="utf-8"))
        sidecar = self.home / ".local/bin/dotfiles-pinentry.json"
        self.assertIn("changed", json.loads(sidecar.read_text(encoding="utf-8"))["fallback"])

    def test_unrelated_data_and_yaml_formatting_do_not_schedule_reload(self):
        self.chezmoi("apply", "--force")
        data = self.source / ".chezmoidata/gpg.yaml"
        text = data.read_text(encoding="utf-8")
        text = text.replace("gpgRecipient: ", "gpgRecipient: unrelated-")
        # Change a different platform's selected defaults as well as YAML comments.
        other = "    pinentry: /usr/bin/pinentry\n" if os.name == "nt" else "    pinentry: C:/Program Files/Gpg4win/bin/pinentry.exe\n"
        text = text.replace(other, other.replace("    pinentry: ", "    pinentry: changed-"))
        data.write_text("# formatting only\n" + text, encoding="utf-8")
        (self.source / ".chezmoidata/unrelated.yaml").write_text("unrelated: changed\n", encoding="utf-8")
        self.assertFalse(self.reload_pending())

    def test_consumed_template_change_schedules_reload(self):
        self.chezmoi("apply", "--force")
        helper = self.source / ".chezmoitemplates/gpg-agent-config"
        with helper.open("a", encoding="utf-8") as stream:
            stream.write("{{/* consumed template changed */}}\n")
        self.assertTrue(self.reload_pending())
        self.chezmoi("apply", "--force")
        self.assertFalse(self.reload_pending())

    def test_failed_reload_is_retryable(self):
        for guard in (self.source / ".chezmoiscripts").glob("run_before_*"):
            guard.unlink()
        self.configure(program=self.root / "missing" / self.program.name)
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.reload_pending())
        self.configure()
        self.chezmoi("apply", "--force")
        self.assertFalse(self.reload_pending())



if __name__ == "__main__":
    unittest.main()
