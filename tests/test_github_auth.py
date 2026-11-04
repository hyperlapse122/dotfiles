import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("github_auth", REPO / "scripts/github-auth.py")


@unittest.skipUnless(shutil.which("chezmoi"), "Chezmoi required")
class GithubAuthApplyTest(unittest.TestCase):
    def setUp(self):
        self.auth = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(self.auth)
        scratch = tempfile.TemporaryDirectory(prefix="github apply ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home"
        self.gh = self.home / ".local/bin" / ("gh.exe" if os.name == "nt" else "gh")
        self.gh.parent.mkdir(parents=True)
        self.gh.touch()
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.metadata = self.root / "gh/hosts.yml"
        self.environment = mock.patch.dict(os.environ, {"GH_CONFIG_DIR": str(self.metadata.parent)})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.token = "dummy-repository-sensitive-token"
        self.store = {}
        self.writes = 0
        real_private = self.auth.run_private

        def private(argv, **kwargs):
            if argv[0] == str(self.gh):
                host = argv[argv.index("--hostname") + 1]
                user = argv[argv.index("--user") + 1] if "--user" in argv else ""
                return self.store.get((host, user), "") + "\n"
            return real_private(argv, **kwargs)

        def get(command, host, user, env):
            return self.store.get((host, user))

        def set_password(command, host, user, token, env):
            self.store[(host, user)] = token
            self.writes += 1

        for name, replacement in (
            ("require_encryption_policy", lambda *args: None),
            ("read_secrets", lambda *args: {"github": {"token": self.token}}),
            ("github_login", lambda token: "owner"),
            ("native_get", get), ("native_set", set_password), ("run_private", private),
        ):
            patcher = mock.patch.object(self.auth, name, side_effect=replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        # This seam represents an installed tool; no native backend is invoked.
        patcher = mock.patch.object(self.auth.shutil, "which", return_value="keyring-fixture")
        patcher.start()
        self.addCleanup(patcher.stop)

    def apply(self):
        self.auth.apply_auth(REPO, self.config, self.home)

    def test_first_apply_repeat_rotation_and_removed_entry_converge(self):
        self.apply()
        expected = {(host, user): self.token for host in self.auth.HOSTS for user in ("owner", "")}
        self.assertTrue(self.store == expected, "native state differs")
        self.assertEqual(set(json.loads(self.metadata.read_text(encoding="utf-8"))), {"github.com"})
        before = self.metadata.stat().st_mtime_ns
        self.apply()
        self.assertEqual(self.writes, 4)
        self.assertEqual(self.metadata.stat().st_mtime_ns, before)
        self.token = "dummy-rotated-token"
        self.apply()
        self.assertTrue(all(value == self.token for value in self.store.values()), "rotation differs")
        self.store.pop(("gist.github.com", "owner"))
        self.apply()
        expected = {(host, user): self.token for host in self.auth.HOSTS for user in ("owner", "")}
        self.assertTrue(self.store == expected, "repair differs")

    def test_competing_gist_credential_is_replaced_without_losing_other_accounts(self):
        self.metadata.parent.mkdir()
        original = {
            "enterprise.invalid": {"user": "other", "oauth_token": "unrelated-preserved"},
            "gist.github.com": {"user": "owner", "oauth_token": "stale-active",
                                "users": {"owner": {"oauth_token": "stale-user", "refresh_token": "stale-refresh"},
                                          "other": {"oauth_token": "other-preserved"}}},
        }
        self.metadata.write_text(json.dumps(original), encoding="utf-8")
        self.store[("gist.github.com", "")] = "stale-active"
        self.apply()
        result = json.loads(self.metadata.read_text(encoding="utf-8"))
        self.assertEqual(result["enterprise.invalid"], original["enterprise.invalid"])
        self.assertEqual(result["gist.github.com"]["users"]["other"], {"oauth_token": "other-preserved"})
        self.assertEqual(result["gist.github.com"]["users"]["owner"], {})
        self.assertNotIn("oauth_token", result["gist.github.com"])
        self.assertTrue(all(value == self.token for value in self.store.values()), "competing credential remained")
        self.assertNotIn(self.token, self.metadata.read_text(encoding="utf-8"))

    def test_literal_tilde_config_reconciles_the_file_gh_reads(self):
        literal = self.root / "~" / "gh-fixture" / "hosts.yml"
        literal.parent.mkdir(parents=True)
        literal.write_text('{"github.com": {"oauth_token": "stale-config-token"}}',
                           encoding="utf-8")
        expanded = self.home / "gh-fixture" / "hosts.yml"
        expanded.parent.mkdir(parents=True)
        untouched = '{"unrelated.invalid": {"user": "untouched"}}'
        expanded.write_text(untouched, encoding="utf-8")
        with mock.patch.dict(os.environ, {
            "GH_CONFIG_DIR": "~/gh-fixture",
            "HOME": str(self.home), "USERPROFILE": str(self.home),
        }), contextlib.chdir(self.root):
            self.apply()
        result = json.loads(literal.read_text(encoding="utf-8"))
        self.assertNotIn("oauth_token", result["github.com"])
        self.assertEqual(result["github.com"]["user"], "owner")
        self.assertEqual(expanded.read_text(encoding="utf-8"), untouched)

    def test_denied_write_cannot_publish_plaintext_fallback(self):
        with mock.patch.object(self.auth, "native_set", side_effect=self.auth.AuthError("denied")):
            with self.assertRaises(self.auth.AuthError):
                self.apply()
        self.assertFalse(self.metadata.exists())
        self.assertEqual(self.store, {})

    def test_failure_after_initial_write_does_not_publish_metadata(self):
        def fail_after_first(command, host, user, token, env):
            if self.store:
                raise self.auth.AuthError("denied")
            self.store[(host, user)] = token
        with mock.patch.object(self.auth, "native_set", side_effect=fail_after_first):
            with self.assertRaises(self.auth.AuthError):
                self.apply()
        self.assertFalse(self.metadata.exists())

    def test_identity_failure_preserves_metadata_and_native_state(self):
        self.metadata.parent.mkdir()
        self.metadata.write_text('{"unrelated": {"user": "other"}}', encoding="utf-8")
        original = self.metadata.read_bytes()
        with mock.patch.object(self.auth, "github_login", side_effect=self.auth.AuthError("identity failed")):
            with self.assertRaises(self.auth.AuthError):
                self.apply()
        self.assertEqual(self.metadata.read_bytes(), original)
        self.assertEqual(self.store, {})

    def test_verification_cannot_use_inherited_auth_or_debug_overrides(self):
        with mock.patch.dict(os.environ, {
            "GH_TOKEN": "different", "GITHUB_TOKEN": "different", "GH_DEBUG": "api",
            "PYTHON_KEYRING_BACKEND": "untrusted", "KEYRING_PROPERTY_SCHEME": "untrusted",
            "GIT_TRACE_CURL": "1", "DBUS_SESSION_BUS_ADDRESS": "preserved-session",
        }):
            env = self.auth.private_environment()
            self.assertFalse(any(name in env for name in (
                "GH_TOKEN", "GITHUB_TOKEN", "GH_DEBUG", "PYTHON_KEYRING_BACKEND",
                "KEYRING_PROPERTY_SCHEME", "GIT_TRACE_CURL")))
            self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "preserved-session")
            self.assertEqual(os.environ["GH_TOKEN"], "different")


class NativeAuthFailureTest(unittest.TestCase):
    def test_successful_command_survives_non_utf8_diagnostics(self):
        auth = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(auth)
        diagnostics = io.StringIO()
        with contextlib.redirect_stderr(diagnostics):
            output = auth.run_private([
                sys.executable, "-c",
                "import os; os.write(1, b'valid\\n'); os.write(2, b'\\xff')",
            ])
        self.assertEqual(output, "valid\n")
        self.assertEqual(diagnostics.getvalue(), "")

    def test_diagnostics_hide_chained_credential_messages(self):
        spec = importlib.util.spec_from_file_location(
            "native_auth_smoke_test", REPO / "tests/smoke_github_auth.py")
        smoke = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(smoke)
        secret = "sensitive-fixture-credential-response"
        try:
            try:
                raise ValueError(secret)
            except ValueError:
                raise RuntimeError(secret) from None
        except RuntimeError as error:
            summary = smoke.failure_summary(error)
        self.assertNotIn(secret, summary)
        self.assertIn("RuntimeError", summary)
        self.assertIn("ValueError", summary)


if __name__ == "__main__":
    unittest.main()
