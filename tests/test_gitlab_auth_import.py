import contextlib
import io
import json
from pathlib import Path
import unittest
from unittest import mock

import test_github_auth_import as fixtures
from test_gitlab_auth import load_auth


@unittest.skipUnless(fixtures.GPG and fixtures.shutil.which("chezmoi"), "GPG and chezmoi required")
class GitlabAuthImportTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GithubAuthImportTest()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        self.auth = load_auth()
        self.connection = self.fixture.root / "connection.json"
        self.values = {"host": "private-git.example.invalid", "registry": "registry.example.invalid", "user": "owner"}
        self.connection.write_text(json.dumps(self.values), encoding="utf-8")

    def run_import(self):
        f = self.fixture
        self.auth.import_token(f.source, f.config, f.token_file, self.connection)

    def test_import_encrypts_private_metadata_and_preserves_other_mappings(self):
        f = self.fixture
        original_private = self.auth.common.run_private

        def private(argv, **kwargs):
            for value in [f.token, *self.values.values()]:
                self.assertFalse(any(value in str(argument) for argument in argv),
                                 "Private data reached a process argument")
            return original_private(argv, **kwargs)

        with mock.patch.object(self.auth.common, "run_private", side_effect=private):
            self.run_import()
        result = self.auth.common.read_secrets(f.source, f.config)
        expected = {**f.previous, "gitlab": {**self.values, "token": f.token}}
        self.assertTrue(result == expected, "Encrypted mapping differs")
        self.assertFalse(f.token_file.exists())
        self.assertTrue(self.connection.exists())
        ciphertext = f.ciphertext.read_text(encoding="utf-8")
        for value in [f.token, *self.values.values()]:
            self.assertNotIn(value, ciphertext)

    def test_missing_user_is_resolved_before_encrypted_publication(self):
        values = {key: value for key, value in self.values.items() if key != "user"}
        self.connection.write_text(json.dumps(values), encoding="utf-8")
        with mock.patch.object(self.auth, "gitlab_user", return_value="resolved-owner"):
            self.run_import()
        result = self.auth.common.read_secrets(self.fixture.source, self.fixture.config)
        self.assertEqual(result["gitlab"]["user"], "resolved-owner")

    def test_invalid_connection_retains_input_and_previous_ciphertext_without_disclosure(self):
        self.connection.write_text(json.dumps({**self.values, "host": "https://secret.invalid/path"}), encoding="utf-8")
        output = io.StringIO()
        f = self.fixture
        with contextlib.redirect_stderr(output):
            result = self.auth.main(["import", "--source", str(f.source), "--config", str(f.config),
                                     "--token-file", str(f.token_file), "--connection-file", str(self.connection)])
        self.assertEqual(result, 1)
        self.assertEqual(f.ciphertext.read_bytes(), f.original)
        self.assertTrue(f.token_file.exists())
        self.assertNotIn("secret.invalid", output.getvalue())
        self.assertNotIn(f.token, output.getvalue())


if __name__ == "__main__":
    unittest.main()
