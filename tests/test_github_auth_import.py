import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_secrets import GPG, OWNER


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
SPEC = importlib.util.spec_from_file_location("github_auth_import", REPO / "scripts/github-auth.py")


def load_auth():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


@unittest.skipUnless(GPG and shutil.which("chezmoi"), "GPG and chezmoi required")
class GithubAuthImportTest(unittest.TestCase):
    def setUp(self):
        self.auth = load_auth()
        scratch = tempfile.TemporaryDirectory(prefix="cgi-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "h"
        self.home.mkdir()
        self.gpg_home = (self.home / "AppData/Roaming/gnupg"
                         if os.name == "nt" else self.root / "keyring")
        self.gpg_home.mkdir(parents=True, mode=0o700)
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        shutil.copy2(REPO / ".chezmoiroot", self.source)
        source_home = self.source / "home"
        (source_home / ".chezmoitemplates").mkdir(parents=True)
        (source_home / ".chezmoidata").mkdir()
        (source_home / ".secrets").mkdir()
        shutil.copy2(REPO / "home/.chezmoi.toml.tmpl", source_home)
        for name in ("gpg-settings", "secrets"):
            shutil.copy2(REPO / "home/.chezmoitemplates" / name,
                         source_home / ".chezmoitemplates" / name)
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
        self.environment = mock.patch.dict(os.environ, self.env, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.stop_agent)
        self.command(GPG, "--no-options", "--batch", "--pinentry-mode", "loopback",
                     "--passphrase", "", "--quick-generate-key",
                     "Import Fixture <import@example.invalid>", "rsa2048", "encr", "1d")
        listing = self.command(GPG, "--no-options", "--with-colons", "--list-keys").stdout
        recipient = next(line.split(":")[9] for line in listing.splitlines()
                         if line.startswith("fpr:"))
        data = (REPO / "home/.chezmoidata/gpg.yaml").read_text(encoding="utf-8")
        (source_home / ".chezmoidata/gpg.yaml").write_text(
            data.replace(OWNER, recipient), encoding="utf-8")
        self.config.write_text('[data]\ngpgProgram = "' + Path(GPG).as_posix() + '"\n',
                               encoding="utf-8")
        self.chezmoi("init")
        self.ciphertext = source_home / ".secrets/api-tokens.yaml.asc"
        self.previous = {
            "example": {"serviceA": "dummy-other-secret", "serviceB": "untouched"},
            "application": {"nested": [1, True, None, {"unicode": "caf\u00e9"}]},
            "github": {"note": "preserve me", "token": "dummy-old-token"},
        }
        encrypted = self.chezmoi("encrypt", input=json.dumps(self.previous)).stdout
        self.ciphertext.write_text(encrypted, encoding="utf-8")
        self.original = self.ciphertext.read_bytes()
        self.token = "dummy-import-sensitive-sentinel"
        self.token_file = self.root / "token.txt"
        self.token_file.write_bytes(b"\xef\xbb\xbf" + self.token.encode() + b"\r\n")

    def command(self, *args, input=None):
        result = subprocess.run(args, input=input, env=self.env, capture_output=True,
                                text=True, encoding="utf-8", errors="backslashreplace", timeout=90)
        # Fixture command outputs are deliberately not included in assertion diagnostics.
        self.assertEqual(result.returncode, 0, "fixture command failed")
        return result

    def chezmoi(self, *args, input=None):
        return self.command("chezmoi", "--source", str(self.source),
                            "--destination", str(self.home), "--config", str(self.config),
                            "--cache", str(self.root / "chezmoi cache"),
                            "--persistent-state", str(self.root / "state.boltdb"),
                            "--no-tty", *args, input=input)

    def stop_agent(self):
        gpgconf = Path(GPG).with_name("gpgconf.exe" if os.name == "nt" else "gpgconf")
        if gpgconf.is_file():
            subprocess.run([str(gpgconf), "--homedir", str(self.gpg_home), "--kill", "all"],
                           env=self.env, capture_output=True, timeout=30)

    def expected(self, token=None):
        result = json.loads(json.dumps(self.previous))
        result["github"]["token"] = self.token if token is None else token
        return result

    def assert_document(self, expected):
        # A fixed assertion label prevents unittest from printing secret-bearing documents.
        actual = self.auth.common.read_secrets(self.source, self.config)
        self.assertTrue(actual == expected, "decrypted document differs")

    def assert_retained(self):
        self.assertTrue(self.token_file.exists(), "input was removed on failure")
        self.assertTrue(self.ciphertext.read_bytes() == self.original,
                        "original ciphertext was changed on failure")
        self.assertEqual(sorted(path.name for path in self.ciphertext.parent.iterdir()),
                         [self.ciphertext.name])

    def run_import(self):
        return self.auth.import_token(self.source, self.config, self.token_file)

    def test_cli_roundtrip_preserves_complete_document_and_deletes_input(self):
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts/github-auth.py"), "import",
             "--source", str(self.source), "--config", str(self.config),
             "--token-file", str(self.token_file)], env=self.env, capture_output=True,
            text=True, encoding="utf-8", timeout=90)
        self.assertEqual(result.returncode, 0, "import command failed")
        self.assertNotIn(self.token, result.stdout + result.stderr)
        self.assert_document(self.expected())
        self.assertFalse(self.token_file.exists())
        self.assertEqual(list(self.ciphertext.parent.iterdir()), [self.ciphertext],
                         "verified publication left a staging or recovery copy")
        for path in self.ciphertext.parent.iterdir():
            self.assertNotIn(self.token.encode(), path.read_bytes())

    def test_runtime_child_arguments_and_files_never_contain_token(self):
        original = self.auth.common.run_private
        arguments = []

        def observe(argv, **kwargs):
            arguments.append(tuple(str(value) for value in argv))
            return original(argv, **kwargs)

        with mock.patch.object(self.auth.common, "run_private", side_effect=observe):
            self.run_import()
        self.assertTrue(all(self.token not in value for argv in arguments for value in argv),
                        "secret appeared in child arguments")
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertTrue(self.token.encode() not in path.read_bytes(),
                                "secret appeared in an extra plaintext file")

    def test_adds_github_mapping_to_arbitrary_existing_document(self):
        del self.previous["github"]
        self.ciphertext.write_text(
            self.chezmoi("encrypt", input=json.dumps(self.previous)).stdout, encoding="utf-8")
        self.run_import()
        expected = dict(self.previous, github={"token": self.token})
        self.assert_document(expected)
        self.assertFalse(self.token_file.exists())

    def test_import_does_not_require_child_plaintext_temporary_files(self):
        unavailable = str(self.root / "unavailable-temporary-directory")
        env = dict(self.env, TMPDIR=unavailable, TMP=unavailable, TEMP=unavailable)
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts/github-auth.py"), "import",
             "--source", str(self.source), "--config", str(self.config),
             "--token-file", str(self.token_file)], env=env, capture_output=True,
            text=True, encoding="utf-8", timeout=90)
        self.assertEqual(result.returncode, 0, "import required a child plaintext temporary file")
        self.assert_document(self.expected())
        self.assertFalse(self.token_file.exists())

    def test_token_spaces_are_preserved(self):
        self.token_file.write_bytes(b" dummy-with-spaces \n")
        self.run_import()
        self.assert_document(self.expected(" dummy-with-spaces "))

    def test_rejects_empty_multiline_and_invalid_utf8_without_publication(self):
        for value in (b"", b"\xef\xbb\xbf\r\n", b"first\nsecond", b"first\n\n", b"\xff"):
            with self.subTest(value_length=len(value)):
                self.token_file.write_bytes(value)
                with self.assertRaises(self.auth.common.AuthError):
                    self.run_import()
                self.assert_retained()

    def test_ciphertext_cannot_be_used_as_deletable_input(self):
        with self.assertRaises(self.auth.common.AuthError):
            self.auth.import_token(self.source, self.config, self.ciphertext)
        self.assert_retained()

    def test_missing_private_key_retains_input_and_ciphertext(self):
        self.stop_agent()
        shutil.rmtree(self.gpg_home / "private-keys-v1.d")
        with self.assertRaises(self.auth.common.AuthError):
            self.run_import()
        self.assert_retained()

    def test_uninitialized_encryption_policy_is_not_rewritten(self):
        self.config.write_text('[data]\ngpgProgram = "' + Path(GPG).as_posix() + '"\n',
                               encoding="utf-8")
        before = self.config.read_bytes()
        with self.assertRaises(self.auth.common.AuthError):
            self.run_import()
        self.assertTrue(self.config.read_bytes() == before, "config was rewritten")
        self.assert_retained()

    def test_child_encryption_failure_is_value_free_and_retains_input(self):
        original = self.auth.common.run_private

        def fail_encrypt(argv, **kwargs):
            if "--encrypt" in argv:
                return original([sys.executable, "-c",
                                 "import sys; value=sys.stdin.read(); "
                                 "print(value); print(value, file=sys.stderr); sys.exit(1)"],
                                input=kwargs.get("input"), operation="Token encryption failed.")
            return original(argv, **kwargs)

        output = io.StringIO()
        with mock.patch.object(self.auth.common, "run_private", side_effect=fail_encrypt), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = self.auth.main(["import", "--source", str(self.source),
                                     "--config", str(self.config),
                                     "--token-file", str(self.token_file)])
        self.assertNotEqual(result, 0)
        self.assertNotIn(self.token, output.getvalue())
        self.assertNotIn("dummy-other-secret", output.getvalue())
        self.assert_retained()

    def test_staged_comparison_failure_retains_original(self):
        original = self.auth.common.read_secrets

        def mismatch(source, config=None, *, ciphertext=None):
            if ciphertext is not None:
                return {"github": {"token": "dummy-different"}}
            return original(source, config)

        with mock.patch.object(self.auth.common, "read_secrets", side_effect=mismatch):
            with self.assertRaises(self.auth.common.AuthError):
                self.run_import()
        self.assert_retained()

    def test_atomic_publication_failure_retains_original(self):
        with mock.patch.object(self.auth.common.os, "replace", side_effect=PermissionError(self.token)):
            with self.assertRaises(self.auth.common.AuthError) as caught:
                self.run_import()
        self.assertNotIn(self.token, str(caught.exception))
        self.assert_retained()

    def test_final_ciphertext_is_reread_before_input_deletion(self):
        original = self.auth.common.os.replace

        def corrupt_after_publish(source, target):
            original(source, target)
            Path(target).write_text("not encrypted", encoding="utf-8")

        with mock.patch.object(self.auth.common.os, "replace", side_effect=corrupt_after_publish):
            with self.assertRaises(self.auth.common.AuthError):
                self.run_import()
        self.assertTrue(self.token_file.exists())
        recovery = [path for path in self.ciphertext.parent.iterdir()
                    if path.name.startswith(".api-tokens-recovery-")]
        self.assertEqual(len(recovery), 1, "prior ciphertext recovery copy was not retained")
        self.assertTrue(recovery[0].read_bytes() == self.original,
                        "recovery copy does not contain the prior ciphertext")
        self.assertTrue(self.token.encode() not in recovery[0].read_bytes(),
                        "recovery copy contains plaintext input")

    def test_input_unlink_failure_keeps_verified_ciphertext_and_reports_cleanup(self):
        original = Path.unlink

        def fail_input(path, *args, **kwargs):
            if path == self.token_file:
                raise PermissionError(self.token)
            return original(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", new=fail_input):
            with self.assertRaises(self.auth.common.AuthError) as caught:
                self.run_import()
        self.assertNotIn(self.token, str(caught.exception))
        self.assertIn("verified", str(caught.exception).lower())
        self.assertTrue(self.token_file.exists())
        self.assert_document(self.expected())
        self.assertEqual(list(self.ciphertext.parent.iterdir()), [self.ciphertext],
                         "verified publication left a staging or recovery copy")


if __name__ == "__main__":
    unittest.main()
