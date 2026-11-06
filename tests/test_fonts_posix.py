import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_native_ca_shell import find_bash


REPO = Path(__file__).resolve().parents[1]


def find_hash_command(shell, search_directory=""):
    result = subprocess.run([
        shell, "--noprofile", "--norc", "-c",
        'if [ -n "$1" ]; then PATH="$(cd "$1" && pwd -P)" || exit; '
        'else PATH=/usr/bin:/bin; fi; export PATH; command -v sha256sum || command -v shasum',
        "fixture", search_directory,
    ], capture_output=True, text=True, check=True)
    command = result.stdout.strip()
    return [command, "-a", "256"] if Path(command).name == "shasum" else [command]


@unittest.skipUnless(find_bash(), "Native Bash or Git Bash required")
class PosixFontsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="font native ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.assets = self.root / "assets"
        self.index = self.root / "index.tsv"
        self.fonts = self.root / "fonts"
        self.state = self.root / "state" / "installed.txt"
        self.bin = self.root / "commands"
        self.bin.mkdir()
        utilities = ("bash", "sh", "awk", "dirname", "mkdir", "mktemp", "cp", "mv", "rm",
                     "cmp", "cat", "grep", "sort", "chmod", "stat", "find")
        result = subprocess.run([find_bash(), "--noprofile", "--norc", "-c",
                                 'PATH=/usr/bin:/bin; for tool; do command -v "$tool" || exit; done',
                                 "fixture", *utilities],
                                capture_output=True, text=True, check=True)
        for name, command in zip(utilities, result.stdout.splitlines(), strict=True):
            self.wrapper(name, "exec " + shlex.quote(command) + ' "$@"')
        self.wrapper("sha256sum", 'if [ -n "${FONT_TEST_HASH_LOG:-}" ]; then printf "%s\\n" "$*" >> "$FONT_TEST_HASH_LOG"; fi; exec ' + shlex.join(find_hash_command(find_bash())) + ' "$@"')
        self.wrapper("uname", 'printf "%s\\n" "${FONT_TEST_OS:-Linux}"')
        self.wrapper("fc-cache", 'printf "refresh\\n" >> "$FONT_TEST_LOG"; exit "${FONT_TEST_CACHE_EXIT:-0}"')
        self.wrapper("shasum", 'shift 2; exec sha256sum "$@"')
        self.env = os.environ.copy()
        self.env.update(FONT_TEST_LOG=(self.root / "refresh.log").as_posix())
        self.write_fonts({"Example.ttf": b"font original"})

    def wrapper(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def write_fonts(self, fonts):
        rows = []
        for name, content in fonts.items():
            path = self.assets / "example" / "nested" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            rows.append("\t".join(("example", "nested/" + name, name, hashlib.sha256(content).hexdigest())))
        self.index.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8", newline="\n")

    def run_installer(self, check=True):
        command = 'PATH="$(cd "$1" && pwd -P)"; export PATH; shift; exec bash --noprofile --norc "$@"'
        result = subprocess.run([
            find_bash(), "--noprofile", "--norc", "-c", command, "fixture", self.bin.as_posix(),
            (REPO / "scripts/install-fonts.sh").as_posix(), self.assets.as_posix(), self.index.as_posix(),
            self.fonts.as_posix(), self.state.as_posix(),
        ], env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_install_repeat_repair_and_owned_cleanup(self):
        self.run_installer()
        installed = self.fonts / "dotfiles-example-Example.ttf"
        self.assertEqual(installed.read_bytes(), b"font original")
        original_time = installed.stat().st_mtime_ns
        unrelated = self.fonts / "personal.ttf"
        unrelated.write_bytes(b"keep")
        self.run_installer()
        self.assertEqual(installed.stat().st_mtime_ns, original_time)
        installed.unlink()
        self.run_installer()
        self.assertEqual(installed.read_bytes(), b"font original")
        self.write_fonts({"New.ttf": b"replacement"})
        self.run_installer()
        self.assertFalse(installed.exists())
        self.assertEqual((self.fonts / "dotfiles-example-New.ttf").read_bytes(), b"replacement")
        self.assertEqual(unrelated.read_bytes(), b"keep")
        self.assertEqual(self.state.read_text(), "dotfiles-example-New.ttf\n")

    def test_all_staged_hashes_checked_before_mutation(self):
        self.run_installer()
        installed = self.fonts / "dotfiles-example-Example.ttf"
        self.write_fonts({"Example.ttf": b"changed", "Later.ttf": b"valid"})
        (self.assets / "example/nested/Later.ttf").write_bytes(b"corrupt")
        result = self.run_installer(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr.lower())
        self.assertEqual(installed.read_bytes(), b"font original")
        self.assertFalse((self.fonts / "dotfiles-example-Later.ttf").exists())

    def test_unchanged_run_skips_payload_hashes_and_explicit_verify_checks_them(self):
        log = self.root / "hashes.log"
        self.env["FONT_TEST_HASH_LOG"] = log.as_posix()
        self.run_installer()
        self.assertTrue(log.read_text())
        log.write_text("")
        self.run_installer()
        self.assertEqual(log.read_text(), "")
        self.env["DOTFILES_ASSET_MODE"] = "verify"
        self.run_installer()
        self.assertTrue(log.read_text())

    def test_explicit_verify_repairs_installed_corruption_with_preserved_metadata(self):
        self.run_installer()
        installed = self.fonts / "dotfiles-example-Example.ttf"
        stamp = installed.stat()
        installed.write_bytes(b"font tampered")
        os.utime(installed, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.run_installer()
        self.assertEqual(installed.read_bytes(), b"font tampered")
        self.env["DOTFILES_ASSET_MODE"] = "verify"
        self.run_installer()
        self.assertEqual(installed.read_bytes(), b"font original")

    def test_bad_manifest_cannot_remove_unowned_files(self):
        self.run_installer()
        outside = self.root / "outside.ttf"
        outside.write_bytes(b"keep")
        for entry in ("../outside.ttf", "personal.ttf", "dotfiles-../outside.ttf"):
            self.state.write_text(entry + "\n")
            self.assertNotEqual(self.run_installer(check=False).returncode, 0)
            self.assertEqual(outside.read_bytes(), b"keep")

    def test_refresh_failure_does_not_write_success_state(self):
        self.env["FONT_TEST_CACHE_EXIT"] = "17"
        self.assertNotEqual(self.run_installer(check=False).returncode, 0)
        self.assertFalse(self.state.exists())
        self.env.pop("FONT_TEST_CACHE_EXIT")
        self.run_installer()
        self.assertTrue(self.state.exists())

    def test_missing_fontconfig_fails_before_installing(self):
        (self.bin / "fc-cache").unlink()
        result = self.run_installer(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fontconfig", result.stderr.lower())
        self.assertFalse(self.fonts.exists())

    def test_darwin_uses_native_hashing_without_fontconfig(self):
        self.env["FONT_TEST_OS"] = "Darwin"
        (self.bin / "fc-cache").unlink()
        self.run_installer()
        self.assertTrue((self.fonts / "dotfiles-example-Example.ttf").exists())
        self.assertFalse((self.root / "refresh.log").exists())

    def test_hash_provider_discovery_with_only_native_shasum(self):
        native = self.root / "native commands"
        native.mkdir()
        provider = native / "shasum"
        provider.write_text(
            '#!/bin/sh\nshift 2\nexec ' + shlex.quote((self.bin / "sha256sum").as_posix()) + ' "$@"\n',
            encoding="utf-8", newline="\n")
        provider.chmod(0o755)
        command = find_hash_command(find_bash(), native.as_posix())
        result = subprocess.run([find_bash(), "--noprofile", "--norc", "-c",
                                 'exec "$@"', "fixture", *command,
                                 (self.assets / "example/nested/Example.ttf").as_posix()],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.split()[0], hashlib.sha256(b"font original").hexdigest())


if __name__ == "__main__":
    unittest.main()
