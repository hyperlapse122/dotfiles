#!/usr/bin/env python3
"""Focused, secret-free tests for the fixed-path restore helper."""

import importlib.machinery
import importlib.util
import io
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/restore-age-identity"
LOADER = importlib.machinery.SourceFileLoader("restore_age_identity", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


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
REAL_LSTAT = os.lstat
REAL_GETEUID = os.geteuid


def _lstat_as(uid=0, gid=0):
    def fake_lstat(path, *args, **kwargs):
        st = REAL_LSTAT(path, *args, **kwargs)
        values = list(st)
        values[4] = uid
        values[5] = gid
        return os.stat_result(values)
    return fake_lstat


class RestoreIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.parent = self.root / "sops-nix"
        self.target = self.parent / "key.txt"
        self.target_patch = mock.patch.object(MODULE, "TARGET", str(self.target))
        self.euid_patch = mock.patch.object(MODULE.os, "geteuid", return_value=0)
        self.chown_patch = mock.patch.object(MODULE.os, "chown", lambda path, uid, gid: None)
        self.lstat_patch = mock.patch.object(MODULE.os, "lstat", side_effect=_lstat_as(0, 0))
        self.target_patch.start()
        self.euid_patch.start()
        self.chown_patch.start()
        self.lstat_patch.start()

    def tearDown(self):
        self.lstat_patch.stop()
        self.chown_patch.stop()
        self.euid_patch.stop()
        self.target_patch.stop()
        self.directory.cleanup()

    def assert_no_staged_files(self):
        if self.parent.exists() and not self.parent.is_symlink():
            leftovers = [p.name for p in self.parent.iterdir() if p.name.startswith(".key-")]
            self.assertEqual(leftovers, [])

    def install(self, payload, expected=RECIPIENT):
        result = MODULE.install_identity(payload, expected)
        self.assert_no_staged_files()
        return result

    def test_packaged_script_has_store_shebang_and_substituted_age_keygen(self):
        source = SCRIPT.read_text()
        first_line = source.splitlines()[0]
        self.assertTrue(
            first_line.startswith("#!/nix/store/") or first_line.startswith("#! /nix/store/"),
            first_line,
        )
        self.assertNotIn("@AGE_KEYGEN@", source)
        self.assertTrue(Path(MODULE.AGE_KEYGEN).is_file(), MODULE.AGE_KEYGEN)

    def test_valid_identity_creates_0700_parent_and_0600_atomic_target(self):
        self.assertFalse(self.parent.exists())
        self.assertTrue(self.install(VALID_PAYLOAD))
        self.assertTrue(self.parent.is_dir())
        self.assertEqual(stat.S_IMODE(self.parent.stat().st_mode), 0o700)
        self.assertEqual(self.target.read_bytes(), VALID_PAYLOAD)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)

    def test_recipient_mismatch_preserves_existing_target(self):
        self.parent.mkdir(mode=0o700)
        self.target.write_bytes(b"OLD")
        self.assertFalse(self.install(VALID_PAYLOAD, expected=OTHER_RECIPIENT))
        self.assertEqual(self.target.read_bytes(), b"OLD")

    def test_corrupt_identity_preserves_existing_target(self):
        self.parent.mkdir(mode=0o700)
        self.target.write_bytes(b"OLD")
        self.assertFalse(self.install(b"CORRUPT"))
        self.assertEqual(self.target.read_bytes(), b"OLD")

    def test_empty_oversized_and_nul_inputs_are_rejected(self):
        self.parent.mkdir(mode=0o700)
        self.target.write_bytes(b"OLD")
        for payload in (b"", b"x" * (MODULE.MAX_IDENTITY_BYTES + 1), b"VALID\x00ID"):
            self.assertFalse(self.install(payload))
            self.assertEqual(self.target.read_bytes(), b"OLD")

    def test_non_root_cannot_install(self):
        with mock.patch.object(MODULE.os, "geteuid", return_value=1000):
            self.assertFalse(self.install(VALID_PAYLOAD))
        self.assertFalse(self.parent.exists())

    def test_non_root_owned_parent_is_rejected(self):
        self.parent.mkdir(mode=0o700)
        with mock.patch.object(MODULE.os, "lstat", side_effect=_lstat_as(1000, 1000)):
            self.assertFalse(self.install(VALID_PAYLOAD))
        self.assertFalse(self.target.exists())

    def test_symlink_parent_is_rejected(self):
        real = self.root / "real"
        real.mkdir(mode=0o700)
        self.parent.symlink_to(real, target_is_directory=True)
        self.assertFalse(self.install(VALID_PAYLOAD))
        self.assertEqual(list(real.iterdir()), [])

    def test_main_entry_point_and_cli_subprocess(self):
        with mock.patch.object(MODULE.sys, "stdin", new=io.TextIOWrapper(io.BytesIO(VALID_PAYLOAD))):
            self.assertEqual(MODULE.main(["--recipient", RECIPIENT]), 0)
        self.assertEqual(self.target.read_bytes(), VALID_PAYLOAD)
        self.assert_no_staged_files()

        oversized = b"x" * (MODULE.MAX_IDENTITY_BYTES + 1)
        with mock.patch.object(MODULE.sys, "stdin", new=io.TextIOWrapper(io.BytesIO(oversized))):
            self.assertEqual(MODULE.main(["--recipient", RECIPIENT]), 1)
        self.assertEqual(self.target.read_bytes(), VALID_PAYLOAD)
        self.assert_no_staged_files()

        with mock.patch.object(MODULE.os, "geteuid", return_value=1000):
            self.assertEqual(MODULE.main(["--recipient", RECIPIENT]), 2)

        if REAL_GETEUID() != 0:
            cli = subprocess.run(
                [str(SCRIPT), "--recipient", RECIPIENT],
                input=VALID_PAYLOAD,
                capture_output=True,
            )
            self.assertEqual(cli.returncode, 2)
            self.assertIn(b"must run as root", cli.stderr)

if __name__ == "__main__":
    unittest.main()
