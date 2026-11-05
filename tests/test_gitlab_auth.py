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


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
SPEC = importlib.util.spec_from_file_location("gitlab_auth", REPO / "scripts/gitlab-auth.py")
REAL_GLAB = shutil.which("glab")


def load_auth():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


@unittest.skipUnless(shutil.which("chezmoi") and shutil.which("git"), "Chezmoi and Git required")
class GitlabAuthApplyTest(unittest.TestCase):
    def setUp(self):
        self.auth = load_auth()
        scratch = tempfile.TemporaryDirectory(prefix="gitlab apply ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home with 'quotes"
        self.glab = self.home / ".local/bin" / ("glab.exe" if os.name == "nt" else "glab")
        self.glab.parent.mkdir(parents=True)
        self.glab.touch()
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.metadata = self.root / "glab/config.yml"
        self.include = self.home / ".local/share/dotfiles/gitlab.gitconfig"
        self.token = "dummy-gitlab-sensitive-token"
        self.host, self.registry, self.user = "git.example.invalid", "registry.example.invalid", "owner"
        self.store, self.writes = {}, 0
        env = mock.patch.dict(os.environ, {"GLAB_CONFIG_DIR": str(self.metadata.parent)})
        env.start()
        self.addCleanup(env.stop)
        original_private = self.auth.common.run_private
        self.original_private = original_private

        def read_secrets(*args):
            return {"github": {"token": "untouched"}, "gitlab": {
                "host": self.host, "registry": self.registry, "user": self.user, "token": self.token}}

        def private(argv, **kwargs):
            if argv[0] == str(self.glab):
                data = self.auth.common.read_mapping(REPO, self.config, self.metadata)["hosts"][self.host]
                value = self.store.get(("glab:" + self.host + ":token", ""), "")
                return "username=" + data["user"] + "\npassword=" + value + "\n"
            return original_private(argv, **kwargs)

        def native_set(command, service, user, token, env):
            self.store[service, user] = token
            self.writes += 1

        for owner, name, replacement in (
            (self.auth.common, "read_secrets", read_secrets),
            (self.auth.common, "native_get", lambda command, service, user, env: self.store.get((service, user))),
            (self.auth.common, "native_set", native_set),
            (self.auth.common, "run_private", private),
            (self.auth, "gitlab_user", lambda host, token: self.user),
        ):
            patcher = mock.patch.object(owner, name, side_effect=replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(self.auth.shutil, "which", return_value="keyring-fixture")
        patcher.start()
        self.addCleanup(patcher.stop)

    def apply(self):
        self.auth.apply_auth(REPO, self.config, self.home)

    def test_repeat_rotation_and_deleted_entry_converge(self):
        self.apply()
        self.apply()
        self.assertEqual(self.writes, 1)
        self.token = "dummy-rotated-token"
        self.apply()
        self.store.clear()
        self.apply()
        self.assertTrue(self.store == {("glab:" + self.host + ":token", ""): self.token},
                        "Managed keyring state did not converge")
        self.assertNotIn(self.token, self.metadata.read_text(encoding="utf-8"))
        self.assertNotIn(self.token, self.include.read_text(encoding="utf-8"))

    def test_managed_pat_overrides_oauth_without_changing_unrelated_configuration(self):
        other = {"token": "unrelated", "user": "someone", "git_protocol": "ssh"}
        self.metadata.parent.mkdir()
        self.metadata.write_text(json.dumps({"host": "other.invalid", "is_oauth2": "true", "hosts": {
            "other.invalid": other,
            self.host: {"token": "stale", "oauth2_refresh_token": "old-refresh", "is_oauth2": "true",
                        "git_protocol": "ssh", "custom": "preserved"}}}), encoding="utf-8")
        self.apply()
        document = json.loads(self.metadata.read_text(encoding="utf-8"))
        self.assertEqual(document["host"], "other.invalid")
        self.assertEqual(document["is_oauth2"], "true")
        self.assertEqual(document["hosts"]["other.invalid"], other)
        managed = document["hosts"][self.host]
        self.assertEqual(managed["is_oauth2"], "false")
        self.assertEqual(managed["use_keyring"], "true")
        self.assertEqual(managed["git_protocol"], "ssh")
        self.assertEqual(managed["custom"], "preserved")
        self.assertNotIn("token", managed)
        self.assertNotIn("oauth2_refresh_token", managed)

    def test_denied_keyring_does_not_publish_metadata_or_helper(self):
        with mock.patch.object(self.auth.common, "native_set", side_effect=self.auth.common.AuthError("denied")):
            with self.assertRaises(self.auth.common.AuthError):
                self.apply()
        self.assertFalse(self.metadata.exists())
        self.assertFalse(self.include.exists())

    def test_identity_mismatch_preserves_local_state(self):
        with mock.patch.object(self.auth, "gitlab_user", return_value="different"):
            with self.assertRaises(self.auth.common.AuthError):
                self.apply()
        self.assertFalse(self.metadata.exists())
        self.assertEqual(self.store, {})

    def test_real_git_reads_host_scoped_helper_and_preserves_other_routing(self):
        self.apply()
        root = self.root / "gitconfig"
        root.write_text('[credential]\n    helper = sentinel\n[include]\n    path = '
                        + json.dumps(self.include.as_posix()) + '\n', encoding="utf-8")
        env = os.environ.copy()
        env.update({"GIT_CONFIG_GLOBAL": str(root), "GIT_CONFIG_NOSYSTEM": "1"})
        for host, expected in ((self.host, "git-credential"), ("unrelated.invalid", "sentinel")):
            result = subprocess.run(["git", "config", "--global", "--includes", "--get-urlmatch",
                                     "credential.helper", "https://" + host], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout)
            if host == self.host:
                self.assertNotIn("sentinel", result.stdout)

    @unittest.skipUnless(REAL_GLAB, "Real glab required for empty-setting compatibility")
    def test_empty_yaml_settings_remain_empty_to_glab_after_apply(self):
        self.metadata.parent.mkdir()
        self.metadata.write_text(
            "last_update_check_timestamp:\nhosts:\n"
            "  other.invalid:\n    ca_cert:\n    subfolder:\n    git_protocol: ssh\n"
            f"  {self.host}:\n    ca_cert:\n", encoding="utf-8")
        self.apply()
        env = self.auth.private_environment()
        for key, host in (("last_update_check_timestamp", None),
                          ("ca_cert", "other.invalid"), ("subfolder", "other.invalid"),
                          ("ca_cert", self.host)):
            with self.subTest(key=key, host=host):
                argv = [REAL_GLAB, "config", "get", key]
                if host:
                    argv.extend(["--host", host])
                result = subprocess.run(argv, env=env, cwd=self.home,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "")
        env.pop("GLAB_CHECK_UPDATE", None)
        result = subprocess.run([REAL_GLAB, "auth"], env=env, cwd=self.home,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('parsing time "null"', result.stderr)
        self.apply()
        document = self.auth.common.read_mapping(REPO, self.config, self.metadata)
        self.assertEqual(document["hosts"]["other.invalid"]["git_protocol"], "ssh")

    @unittest.skipUnless(REAL_GLAB, "Real glab required for config-path contract")
    def test_relative_config_is_used_from_verification_working_directory(self):
        selected_users = []
        def private(argv, **kwargs):
            if argv[0] == str(self.glab):
                user = self.original_private(
                    [REAL_GLAB, "config", "get", "user", "--host", self.host],
                    env=kwargs["env"], cwd=kwargs["cwd"],
                    operation="Real glab could not read relative configuration.",
                ).strip()
                selected_users.append(user)
                token = self.store.get(("glab:" + self.host + ":token", ""), "")
                return "username=" + user + "\npassword=" + token + "\n"
            return self.original_private(argv, **kwargs)

        with (contextlib.chdir(self.root),
              mock.patch.dict(os.environ, {"GLAB_CONFIG_DIR": "glab"}),
              mock.patch.object(self.auth.common, "run_private", side_effect=private)):
            self.apply()
        self.assertEqual(selected_users[0], self.user)

    @unittest.skipUnless(REAL_GLAB, "Real glab required for XDG configuration preservation")
    def test_system_configuration_survives_first_apply_then_user_configuration_wins(self):
        system = self.root / "system/glab-cli/config.yml"
        system.parent.mkdir(parents=True)
        original = {"host": "other.invalid", "git_protocol": "https",
                    "glamour_style_auto_migrated": "true", "hosts": {
                        "other.invalid": {"user": "another-owner", "custom": "preserved"}}}
        system.write_text(json.dumps(original, indent=2), encoding="utf-8")
        system_bytes = system.read_bytes()
        self.metadata = self.root / "xdg/glab-cli/config.yml"
        with (mock.patch.dict(os.environ, {
                  "GLAB_CONFIG_DIR": "", "XDG_CONFIG_HOME": str(self.metadata.parent.parent),
                  "XDG_CONFIG_DIRS": str(system.parent.parent), "HOME": str(self.home),
                  "USERPROFILE": str(self.home)}),
              mock.patch.object(Path, "home", return_value=self.home)):
            def protocol():
                return self.original_private(
                    [REAL_GLAB, "config", "get", "git_protocol"],
                    env=self.auth.private_environment(), cwd=self.home,
                    operation="Real glab could not read isolated XDG configuration.",
                ).strip()

            self.assertEqual(protocol(), "https")
            self.assertFalse(self.metadata.exists())
            self.apply()
            document = json.loads(self.metadata.read_text(encoding="utf-8"))
            self.assertEqual(document["host"], original["host"])
            self.assertEqual(document["hosts"]["other.invalid"], original["hosts"]["other.invalid"])
            self.assertEqual(protocol(), "https")
            document["git_protocol"] = "ssh"
            self.metadata.write_text(json.dumps(document, indent=2), encoding="utf-8")
            self.apply()
            self.assertEqual(protocol(), "ssh")
        self.assertEqual(system.read_bytes(), system_bytes)

    def test_failed_cli_selection_withholds_new_git_helper(self):
        with mock.patch.object(self.auth, "verify_credential",
                               side_effect=self.auth.common.AuthError("mismatch")):
            with self.assertRaises(self.auth.common.AuthError):
                self.apply()
        self.assertFalse(self.include.exists())


class GitlabPrivateEnvironmentTest(unittest.TestCase):
    def test_verification_drops_credential_and_identity_overrides_without_mutating_session(self):
        auth = load_auth()
        overrides = {"GITLAB_TOKEN": "other", "GLAB_IS_OAUTH2": "true", "GLAB_DEBUG_HTTP": "true",
                     "GITLAB_HOST": "other.invalid", "CI_JOB_TOKEN": "other", "GITLAB_CI": "true",
                     "GLAB_ENABLE_CI_AUTOLOGIN": "true", "GIT_TRACE_CURL": "1",
                     "PYTHON_KEYRING_BACKEND": "untrusted", "KEYRING_PROPERTY_SCHEME": "untrusted",
                     "GLAB_CONFIG_DIR": "~/literal-config", "DBUS_SESSION_BUS_ADDRESS": "session"}
        with mock.patch.dict(os.environ, overrides):
            env = auth.private_environment()
            for name in overrides.keys() - {"GLAB_CONFIG_DIR", "DBUS_SESSION_BUS_ADDRESS"}:
                self.assertNotIn(name, env)
            self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "session")
            self.assertEqual(env["GLAB_CONFIG_DIR"], "~/literal-config")
            self.assertEqual(os.environ["GITLAB_TOKEN"], "other")

    def test_existing_legacy_config_precedes_xdg_but_explicit_path_is_literal(self):
        auth = load_auth()
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            legacy = home / ".config/glab-cli"
            legacy.mkdir(parents=True)
            (legacy / "config.yml").write_text("{}", encoding="utf-8")
            with mock.patch.object(Path, "home", return_value=home), mock.patch.dict(
                    os.environ, {"GLAB_CONFIG_DIR": "", "XDG_CONFIG_HOME": str(home / "xdg")}):
                self.assertEqual(auth.glab_config_directory(), legacy)
                with mock.patch.dict(os.environ, {"GLAB_CONFIG_DIR": "~/literal-config"}):
                    self.assertEqual(auth.glab_config_directory(), Path("~/literal-config"))

    def test_private_errors_do_not_print_connection_or_token_values(self):
        auth = load_auth()
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            result = auth.main(["import", "--token-file", "missing-token", "--connection-file", "missing-connection"])
        self.assertEqual(result, 1)
        self.assertNotIn("missing-connection", output.getvalue())


if __name__ == "__main__":
    unittest.main()
