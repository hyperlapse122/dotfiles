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
        self.home = self.root / "user home"
        self.home.mkdir()
        self.gpg_home = self.home / ("AppData/Roaming/gnupg" if os.name == "nt" else ".gnupg")
        self.gpg_home.mkdir(parents=True)
        self.agent = self.gpg_home / "gpg-agent.conf"
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
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

    def run_command(self, *args, check=True):
        result = subprocess.run(args, env=self.env, capture_output=True, text=True,
                                encoding="utf-8", errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def chezmoi(self, *args, check=True):
        return self.run_command(
            "chezmoi", "--source", str(self.repo), "--destination", str(self.home),
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
        result = self.chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reconcile the GPG home", result.stdout + result.stderr)
        self.assertEqual(gitconfig.read_bytes(), b"# existing Git settings\n")
        self.assertEqual(self.agent.read_bytes(), b"# existing agent settings\n")


if __name__ == "__main__":
    unittest.main()
