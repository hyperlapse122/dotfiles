#!/usr/bin/env python3
"""Focused, secret-free tests for the user-mode age identity installer.

The installer places a host's recovered age identity at
~/.config/nix-config/age/key.txt on a non-NixOS host. Each test runs the
packaged script directly as a subprocess against a temporary HOME and
ephemeral age-keygen identities, so no real card is involved.
"""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/install-user-age-identity"

def _generate_identity():
    with tempfile.TemporaryDirectory() as tmp:
        key_file = Path(tmp) / "key.txt"
        subprocess.run(["age-keygen", "-o", str(key_file)], check=True, capture_output=True)
        recipient = subprocess.run(
            ["age-keygen", "-y", str(key_file)], check=True, capture_output=True, text=True
        ).stdout.strip()
        return key_file.read_bytes(), recipient


VALID_PAYLOAD, RECIPIENT = _generate_identity()
OTHER_PAYLOAD, OTHER_RECIPIENT = _generate_identity()


class InstallUserIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name) / "home"
        self.home.mkdir()
        self.target = self.home / ".config/nix-config/age/key.txt"

    def tearDown(self):
        self.directory.cleanup()

    def run_installer(self, payload, recipient=RECIPIENT):
        env = dict(os.environ, HOME=str(self.home))
        return subprocess.run(
            [str(SCRIPT), "--recipient", recipient],
            input=payload,
            env=env,
            capture_output=True,
        )

    def test_packaged_script_has_store_shebang_and_substituted_age_keygen(self):
        source = SCRIPT.read_text()
        first_line = source.splitlines()[0]
        self.assertTrue(
            first_line.startswith("#!/nix/store/") or first_line.startswith("#! /nix/store/"),
            first_line,
        )
        self.assertNotIn("@", source)
        self.assertNotIn("INSTALL_USER_AGE_KEYGEN", source)

    def test_installs_valid_identity_privately(self):
        result = self.run_installer(VALID_PAYLOAD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_bytes(), VALID_PAYLOAD)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.target.parent.stat().st_mode), 0o700)
        self.assertEqual(self.target.stat().st_uid, os.getuid())

    def test_refuses_recipient_mismatch_and_keeps_existing(self):
        self.target.parent.mkdir(parents=True, mode=0o700)
        self.target.write_bytes(b"OLD\n")
        result = self.run_installer(OTHER_PAYLOAD)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"recipient mismatch", result.stderr)
        self.assertEqual(self.target.read_bytes(), b"OLD\n")
        self.assertEqual([p.name for p in self.target.parent.iterdir()], ["key.txt"])

    def test_refuses_corrupt_identity_and_keeps_existing(self):
        self.target.parent.mkdir(parents=True, mode=0o700)
        self.target.write_bytes(b"OLD\n")
        result = self.run_installer(b"CORRUPT-ID\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_bytes(), b"OLD\n")
        self.assertEqual([p.name for p in self.target.parent.iterdir()], ["key.txt"])

    def test_refuses_symlinked_target(self):
        self.target.parent.mkdir(parents=True, mode=0o700)
        elsewhere = Path(self.directory.name) / "elsewhere"
        elsewhere.write_bytes(b"UNTOUCHED\n")
        self.target.symlink_to(elsewhere)
        result = self.run_installer(VALID_PAYLOAD)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(elsewhere.read_bytes(), b"UNTOUCHED\n")
        self.assertTrue(self.target.is_symlink())

    def test_refuses_symlinked_directory(self):
        real = Path(self.directory.name) / "real-age"
        real.mkdir(mode=0o700)
        (self.home / ".config/nix-config").mkdir(parents=True)
        (self.home / ".config/nix-config/age").symlink_to(real)
        result = self.run_installer(VALID_PAYLOAD)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(real.iterdir()), [])

    def assert_refused_before_staging(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.target.exists())
        parent = self.target.parent
        if parent.exists():
            self.assertEqual([p.name for p in parent.iterdir()], [])

    def test_refuses_empty_identity(self):
        self.assert_refused_before_staging(self.run_installer(b""), b"empty or too large")

    def test_refuses_oversized_identity(self):
        self.assert_refused_before_staging(self.run_installer(b"x" * 8193), b"empty or too large")

    def test_refuses_identity_with_nul_bytes(self):
        self.assert_refused_before_staging(self.run_installer(b"VALID\x00ID\n"), b"NUL bytes")

    def test_refuses_invalid_recipient_argument(self):
        self.assert_refused_before_staging(
            self.run_installer(VALID_PAYLOAD, recipient="not-a-recipient"), b"expected recipient is invalid"
        )

    def test_mismatch_leaves_no_staged_file(self):
        self.run_installer(OTHER_PAYLOAD)
        self.assertEqual([p.name for p in self.target.parent.iterdir()], [])

    def test_never_prints_the_identity(self):
        secret_line = next(
            line for line in OTHER_PAYLOAD.splitlines() if line.startswith(b"AGE-SECRET-KEY-")
        )
        result = self.run_installer(OTHER_PAYLOAD)
        self.assertNotIn(secret_line, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
