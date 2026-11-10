#!/usr/bin/env python3
"""Standalone tests for docker-credential-sops."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/docker-credential-sops"


class DockerCredentialSopsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_dir = Path(self.tmp.name)
        self.secrets_dir = self.tmp_dir / "secrets"
        self.secrets_dir.mkdir()

        # Seed three distinct fake tokens for three registries
        self.tokens = {
            "ghcr.io": "FAKE_TOKEN_GHCR_ALPHA_12345",
            "registry.gitlab.com": "FAKE_TOKEN_GITLAB_BETA_67890",
            "registry.jpi.app": "FAKE_TOKEN_JPI_GAMMA_ABCDE",
        }
        self.usernames = {
            "ghcr.io": "octocat",
            "registry.gitlab.com": "gitlab-user",
            "registry.jpi.app": "jpi-user",
        }

        self.secret_files = {}
        for reg, token_val in self.tokens.items():
            secret_file = self.secrets_dir / f"{reg.replace('.', '_')}_token"
            secret_file.write_text(token_val + "\n")
            self.secret_files[reg] = secret_file

        self.mapping = {
            reg: {
                "username": self.usernames[reg],
                "secret": str(self.secret_files[reg]),
            }
            for reg in self.tokens
        }
        self.map_file = self.tmp_dir / "credential-map.json"
        self.map_file.write_text(json.dumps(self.mapping, indent=2))

    def run_helper(self, action, stdin_data=""):
        cmd = [sys.executable, str(SCRIPT), "--map", str(self.map_file), action]
        return subprocess.run(
            cmd,
            input=stdin_data,
            capture_output=True,
            text=True,
        )

    def assert_miss(self, proc):
        self.assertEqual(proc.returncode, 1)
        self.assertIn(
            proc.stdout,
            ("credentials not found in native keychain", "credentials not found in native keychain\n"),
        )
        self.assertEqual(proc.stderr, "")

    def test_unmapped_registry(self):
        proc = self.run_helper("get", stdin_data="unmapped.docker.io\n")
        self.assert_miss(proc)

    def test_secret_file_absent(self):
        absent_path = self.secrets_dir / "nonexistent_token"
        self.mapping["absent.registry.io"] = {
            "username": "user",
            "secret": str(absent_path),
        }
        self.map_file.write_text(json.dumps(self.mapping, indent=2))

        proc = self.run_helper("get", stdin_data="absent.registry.io\n")
        self.assert_miss(proc)

    def test_secret_file_empty_or_whitespace_only(self):
        empty_file = self.secrets_dir / "empty_token"
        empty_file.write_text("")
        ws_file = self.secrets_dir / "whitespace_token"
        ws_file.write_text("   \n\t  \r\n")

        self.mapping["empty.registry.io"] = {"username": "user", "secret": str(empty_file)}
        self.mapping["whitespace.registry.io"] = {"username": "user", "secret": str(ws_file)}
        self.map_file.write_text(json.dumps(self.mapping, indent=2))

        for reg in ("empty.registry.io", "whitespace.registry.io"):
            with self.subTest(registry=reg):
                proc = self.run_helper("get", stdin_data=f"{reg}\n")
                self.assert_miss(proc)

    def test_trailing_newline_stripping(self):
        token_val = "RAW_TOKEN_WITH_NEWLINES_789"
        file_path = self.secrets_dir / "trailing_newlines_token"
        file_path.write_text(f"{token_val}\r\n\n\n  \n")

        self.mapping["trailing.registry.io"] = {"username": "user", "secret": str(file_path)}
        self.map_file.write_text(json.dumps(self.mapping, indent=2))

        proc = self.run_helper("get", stdin_data="trailing.registry.io\n")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stderr, "")
        data = json.loads(proc.stdout)
        self.assertEqual(data["Secret"], token_val)

    def test_distinct_value_routing(self):
        # Mandatory: seed at least three registries with three different tokens
        self.assertGreaterEqual(len(self.tokens), 3)
        self.assertEqual(len(set(self.tokens.values())), len(self.tokens))

        for reg, expected_token in self.tokens.items():
            with self.subTest(registry=reg):
                proc = self.run_helper("get", stdin_data=f"{reg}\n")
                self.assertEqual(proc.returncode, 0)
                self.assertEqual(proc.stderr, "")
                data = json.loads(proc.stdout)
                self.assertEqual(set(data), {"ServerURL", "Username", "Secret"})
                self.assertEqual(data["ServerURL"], reg)
                self.assertEqual(data["Username"], self.usernames[reg])
                self.assertEqual(data["Secret"], expected_token)

    def test_store(self):
        payload = json.dumps({
            "ServerURL": "ghcr.io",
            "Username": "octocat",
            "Secret": "discarded_secret",
        })
        proc = self.run_helper("store", stdin_data=payload)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertIn("declaratively", proc.stderr)

    def test_erase(self):
        proc = self.run_helper("erase", stdin_data="ghcr.io\n")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertIn("declaratively", proc.stderr)

    def test_list(self):
        proc = self.run_helper("list", stdin_data="unused")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stderr, "")
        data = json.loads(proc.stdout)
        self.assertEqual(data, self.usernames)

    def test_leak_guard(self):
        oversized_token = "LEAK_OVERSIZED_" + ("X" * 8500)
        oversized_file = self.secrets_dir / "oversized_token"
        oversized_file.write_text(oversized_token)

        ws_token = "LEAK_SECRET WITH SPACE"
        ws_file = self.secrets_dir / "ws_token"
        ws_file.write_text(ws_token)

        ctrl_token = "LEAK_SECRET\x00NULL"
        ctrl_file = self.secrets_dir / "ctrl_token"
        ctrl_file.write_text(ctrl_token)

        self.mapping["oversized.registry.io"] = {"username": "user", "secret": str(oversized_file)}
        self.mapping["space.registry.io"] = {"username": "user", "secret": str(ws_file)}
        self.mapping["ctrl.registry.io"] = {"username": "user", "secret": str(ctrl_file)}
        self.mapping["absent.registry.io"] = {"username": "user", "secret": str(self.secrets_dir / "missing")}
        self.map_file.write_text(json.dumps(self.mapping, indent=2))

        sensitive_tokens = list(self.tokens.values()) + [
            oversized_token,
            ws_token,
            ctrl_token,
        ]

        miss_cases = [
            ("unmapped.domain.test", "unmapped registry"),
            ("absent.registry.io", "absent secret file"),
            ("oversized.registry.io", "oversized secret (>8192)"),
            ("space.registry.io", "whitespace in secret"),
            ("ctrl.registry.io", "control char in secret"),
        ]

        for reg, case_name in miss_cases:
            with self.subTest(case=case_name):
                proc = self.run_helper("get", stdin_data=f"{reg}\n")
                self.assert_miss(proc)
                for sensitive in sensitive_tokens:
                    self.assertNotIn(sensitive, proc.stdout)
                    self.assertNotIn(sensitive, proc.stderr)

    def test_unknown_action(self):
        proc = self.run_helper("unknown_action", stdin_data="")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stdout, "")
        self.assertIn("unknown action", proc.stderr)


if __name__ == "__main__":
    unittest.main()
