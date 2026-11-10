"""Drive claude-desktop-release against Debian Packages fixtures.

The helper's `curl` command is stubbed on `PATH` so these tests feed it
Packages text fixtures instead of network calls.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-desktop-release"

SAMPLE_PACKAGES = """Package: irrelevant-package
Version: 1.0.0
Architecture: amd64
SHA256: 0000000000000000000000000000000000000000000000000000000000000000
Filename: pool/main/i/irrelevant-package/irrelevant-package_1.0.0_amd64.deb

Package: claude-desktop
Version: 1.17180.0
Architecture: amd64
Filename: pool/main/c/claude-desktop/claude-desktop_1.17180.0_amd64.deb
SHA256: 798e373af6fa46edc59b1cb3229a6104fc38ccf66cb9bfeeea698437fa03f5bd

Package: claude-desktop
Version: 2.2553.0
Architecture: amd64
Filename: pool/main/c/claude-desktop/claude-desktop_2.2553.0_amd64.deb
SHA256: e605cfda93f3f00dfb10f314f52c0f38266d42a23bf9baf8fc0261ab855a6388

Package: claude-desktop
Version: 2.2553.1
Architecture: amd64
Filename: pool/main/c/claude-desktop/claude-desktop_2.2553.1_amd64.deb
SHA256: 6700fdd84e77a6b8c93912c2f69eb5d1e40fa99bcd9d37f438f809ef2a6fe6f8
"""

DEFAULT_URL = "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages"

FAKE_CURL = """#!{python}
import os, sys
expected = ['-sfL', '--max-time', '60', os.environ['FAKE_EXPECTED_URL']]
if sys.argv[1:] != expected:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}} != {{expected!r}}\\n')
    sys.exit(99)
status = int(os.environ.get('FAKE_FETCH_STATUS', '0'))
if status:
    sys.exit(status)
sys.stdout.write(os.environ['FAKE_FETCH_BODY'])
"""


class ClaudeDesktopReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)

    def run_release(self, body, extra_args=None, status=0):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_EXPECTED_URL"] = DEFAULT_URL
        env["FAKE_FETCH_BODY"] = body
        env["FAKE_FETCH_STATUS"] = str(status)
        args = [sys.executable, str(SCRIPT)]
        if extra_args:
            args.extend(extra_args)
        else:
            args.append("--dry-run")
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_picks_the_highest_version_numerically(self):
        result = self.run_release(SAMPLE_PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["version"], "2.2553.1")
        self.assertEqual(data["sha256"], "6700fdd84e77a6b8c93912c2f69eb5d1e40fa99bcd9d37f438f809ef2a6fe6f8")
        self.assertEqual(data["hash"], "sha256-ZwD92E53prjJORLC9p610eQPqZvNnTf0OPgJ7ypv5vg=")

    def test_numeric_version_comparison_beats_lexical(self):
        packages = """Package: claude-desktop
Version: 2.9.0
Architecture: amd64
SHA256: 0000000000000000000000000000000000000000000000000000000000000001
Filename: pool/main/c/claude-desktop/claude-desktop_2.9.0_amd64.deb

Package: claude-desktop
Version: 2.10.0
Architecture: amd64
SHA256: 0000000000000000000000000000000000000000000000000000000000000002
Filename: pool/main/c/claude-desktop/claude-desktop_2.10.0_amd64.deb
"""
        result = self.run_release(packages)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["version"], "2.10.0")

    def test_ignores_non_amd64_architectures(self):
        packages = """Package: claude-desktop
Version: 3.0.0
Architecture: arm64
SHA256: 0000000000000000000000000000000000000000000000000000000000000001
Filename: pool/main/c/claude-desktop/claude-desktop_3.0.0_arm64.deb

Package: claude-desktop
Version: 2.2553.1
Architecture: amd64
SHA256: 6700fdd84e77a6b8c93912c2f69eb5d1e40fa99bcd9d37f438f809ef2a6fe6f8
Filename: pool/main/c/claude-desktop/claude-desktop_2.2553.1_amd64.deb
"""
        result = self.run_release(packages)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["version"], "2.2553.1")

    def test_writes_to_output_file_when_changed(self):
        output_file = Path(self.tmp.name) / "version.json"
        result = self.run_release(SAMPLE_PACKAGES, extra_args=["-o", str(output_file)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output_file.exists())
        data = json.loads(output_file.read_text())
        self.assertEqual(data["version"], "2.2553.1")
        self.assertIn("updated", result.stdout)

        # Run again with same content -> already up to date
        result2 = self.run_release(SAMPLE_PACKAGES, extra_args=["-o", str(output_file)])
        self.assertEqual(result2.returncode, 0, result2.stderr)
        self.assertIn("already up to date", result2.stdout)

    def test_no_matching_package_fails(self):
        packages = """Package: some-other-pkg
Version: 1.0.0
SHA256: 0000000000000000000000000000000000000000000000000000000000000000
"""
        result = self.run_release(packages)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid claude-desktop packages found", result.stderr)

    def test_fetch_error_fails(self):
        result = self.run_release("", status=2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed with status 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
