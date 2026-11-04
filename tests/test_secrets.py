import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


OWNER = "621512777E6933FEB4458FDC4945855D4F283F05"
GPG = (str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "GnuPG/bin/gpg.exe")
       if os.name == "nt" else shutil.which("gpg"))
if GPG and not Path(GPG).is_file():
    GPG = shutil.which("gpg")


@unittest.skipUnless(GPG and shutil.which("chezmoi"), "GPG and chezmoi required")
class SecretsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="csg-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "h"
        self.home.mkdir()
        # Unix needs a non-default home to avoid the per-user default agent socket.
        # Windows already isolates sockets by profile; keep its short native layout.
        self.gpg_home = (self.home / "AppData/Roaming/gnupg"
                         if os.name == "nt" else self.root / "keyring")
        self.gpg_home.mkdir(parents=True, mode=0o700)
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copy2(self.repo / ".chezmoiroot", self.source)
        # Secret proofs must not fetch production apps or run personal PATH hooks.
        shutil.copytree(self.repo / "home", self.source / "home", ignore=shutil.ignore_patterns(
            ".chezmoiexternals", "personal-app*.json", "run_after_10-personal-app-path.*",
        ))
        self.config = self.root / "chezmoi.toml"
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
        self.addCleanup(self.stop_agent)
        self.owner = self.make_key("Fixture Owner <owner@example.invalid>")
        self.other = self.make_key("Other Recipient <other@example.invalid>")
        data = self.source / "home/.chezmoidata/gpg.yaml"
        data.write_text(data.read_text(encoding="utf-8").replace(OWNER, self.owner), encoding="utf-8")
        self.config.write_text(
            'encryption = "age"\n[gpg]\nrecipient = "' + self.other + '"\n'
            'recipients = ["' + self.other + '"]\nsymmetric = true\n'
            'args = ["--recipient", "' + self.other + '"]\n'
            '[data]\ngpgProgram = "' + Path(GPG).as_posix() + '"\n', encoding="utf-8")
        self.ciphertext = self.source / "home/.secrets/api-tokens.yaml.asc"
        self.target = self.home / ".token-proof"

    def command(self, *args, input=None, check=True):
        result = subprocess.run(args, input=input, env=self.env, capture_output=True,
                                text=True, encoding="utf-8", errors="backslashreplace", timeout=90)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def stop_agent(self):
        gpgconf = Path(GPG).with_name("gpgconf.exe" if os.name == "nt" else "gpgconf")
        if gpgconf.is_file():
            self.command(str(gpgconf), "--homedir", str(self.gpg_home), "--kill", "all", check=False)

    def make_key(self, identity):
        self.command(GPG, "--no-options", "--batch", "--pinentry-mode", "loopback",
                     "--passphrase", "", "--quick-generate-key", identity, "rsa2048", "encr", "1d")
        listing = self.command(GPG, "--no-options", "--with-colons", "--list-keys", identity).stdout
        return next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))

    def chezmoi(self, *args, input=None, check=True, config=None):
        return self.command(
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(config or self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", *args,
            input=input, check=check,
        )

    def initialize(self):
        self.chezmoi("init")

    def add_consumer(self):
        (self.source / "home/private_dot_token-proof.tmpl").write_text(
            '{{ (includeTemplate "secrets" . | fromYaml).example.serviceB }}', encoding="utf-8")

    def encrypt_dummy(self):
        plaintext = "example:\n  serviceA: dummy-api-token-a\n  serviceB: dummy-api-token-b\n"
        ciphertext = self.chezmoi("encrypt", input=plaintext).stdout
        self.ciphertext.write_text(ciphertext, encoding="utf-8")
        return ciphertext

    def test_effective_ciphertext_has_only_owner_despite_local_recipient_options(self):
        (self.gpg_home / "gpg.conf").write_text(
            "recipient " + self.other + "\n"
            "encrypt-to " + self.other + "\n"
            "hidden-encrypt-to " + self.other + "\n"
            "group " + self.owner + "=" + self.other + "\n", encoding="utf-8")
        self.initialize()
        ciphertext = self.encrypt_dummy()
        packets = self.command(GPG, "--no-options", "--batch", "--list-only", "--list-packets",
                               input=ciphertext).stdout
        recipients = re.findall(r":pubkey enc packet:.*keyid ([0-9A-F]+)", packets)
        self.assertEqual(recipients, [self.owner[-16:]])
        self.assertNotIn(":symkey enc packet:", packets)
        self.assertNotIn("dummy-api-token-a", ciphertext)
        self.assertNotIn("dummy-api-token-b", ciphertext)

    def test_named_token_application_reconciles_destination_drift(self):
        self.initialize()
        self.encrypt_dummy()
        self.add_consumer()
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "dummy-api-token-b")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "dummy-api-token-b")
        self.target.write_text("local drift", encoding="utf-8")
        self.chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "dummy-api-token-b")

    def test_missing_private_key_preserves_existing_destination(self):
        self.initialize()
        self.encrypt_dummy()
        self.add_consumer()
        self.target.write_bytes(b"existing secret-bearing configuration\n")
        self.stop_agent()
        shutil.rmtree(self.gpg_home / "private-keys-v1.d")
        result = self.chezmoi("apply", "--force", "--exclude=scripts", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), b"existing secret-bearing configuration\n")

    def test_preparation_and_initialization_never_decrypt_ignored_source(self):
        self.ciphertext.write_text("deliberately invalid ciphertext", encoding="utf-8")
        self.add_consumer()
        self.stop_agent()
        shutil.rmtree(self.gpg_home / "private-keys-v1.d")
        self.initialize()
        bootstrap = self.chezmoi("managed", "--exclude=scripts",
                                 config=self.repo / ".chezmoi-bootstrap.toml")
        self.assertNotIn(".secrets", bootstrap.stdout)
        self.assertFalse(self.target.exists())
        self.assertFalse((self.home / ".gitconfig").exists())


if __name__ == "__main__":
    unittest.main()
