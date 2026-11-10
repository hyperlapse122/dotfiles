"""Drive claude-code-release against fake /latest and manifest.zst.json fixtures.

The helper's `curl` command is stubbed on `PATH` so these tests feed it
two-call fixtures keyed by the exact requested URL instead of network calls.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-code-release"

SAMPLE_MANIFEST = {
    "version": "2.1.280",
    "platforms": {
        "linux-x64": {
            "binary": "claude.zst",
            "checksum": "27910e2ae704d8f2e8024897d8fdf1e7710807baf4f6982c0e3797c058315384",
            "size": 82761570,
        },
        "linux-arm64": {
            "binary": "claude.zst",
            "checksum": "a4c1f1d6e3b0b9e5c0f7e2d8a1b6c3d9e4f5a0b1c2d3e4f5a6b7c8d9e0f1a2b3",
            "size": 80653142,
        },
    },
}

FAKE_CURL = """#!{python}
import os, sys
if sys.argv[1:4] != ['-sfL', '--max-time', '60'] or len(sys.argv) != 5:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}}\\n')
    sys.exit(99)
url = sys.argv[4]
base = os.environ['FAKE_BASE_URL']
latest = os.environ.get('FAKE_LATEST_BODY', '').strip()
if url == f'{{base}}/latest':
    status = int(os.environ.get('FAKE_LATEST_STATUS', '0'))
    if status:
        sys.exit(status)
    sys.stdout.write(os.environ.get('FAKE_LATEST_BODY', ''))
elif url == f'{{base}}/{{latest}}/manifest.zst.json':
    status = int(os.environ.get('FAKE_MANIFEST_STATUS', '0'))
    if status:
        sys.exit(status)
    sys.stdout.write(os.environ.get('FAKE_MANIFEST_BODY', ''))
else:
    sys.stderr.write(f'unexpected curl url: {{url!r}}\\n')
    sys.exit(98)
"""


class ClaudeCodeReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)

    def run_release(
        self,
        latest_body="2.1.280",
        manifest_body=None,
        extra_args=None,
        latest_status=0,
        manifest_status=0,
    ):
        if manifest_body is None:
            manifest_body = json.dumps(SAMPLE_MANIFEST)
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_BASE_URL"] = "https://downloads.claude.ai/claude-code-releases"
        env["FAKE_LATEST_BODY"] = latest_body
        env["FAKE_LATEST_STATUS"] = str(latest_status)
        env["FAKE_MANIFEST_BODY"] = manifest_body
        env["FAKE_MANIFEST_STATUS"] = str(manifest_status)
        args = [sys.executable, str(SCRIPT)]
        if extra_args:
            args.extend(extra_args)
        else:
            args.append("--dry-run")
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def test_writes_to_output_file_when_newer(self):
        output_file = Path(self.tmp.name) / "manifest.json"
        result = self.run_release(extra_args=["-o", str(output_file)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output_file.exists())
        data = json.loads(output_file.read_text())
        self.assertEqual(data["version"], "2.1.280")
        self.assertIn("updated", result.stdout)

    def test_manifest_fetch_is_actually_skipped_when_not_newer(self):
        # Proves the skip is real, not incidental: point the manifest
        # endpoint at a failure and confirm the resolver never calls it
        # because the version check alone already settles "nothing to do".
        output_file = Path(self.tmp.name) / "manifest.json"
        output_file.write_text(json.dumps(SAMPLE_MANIFEST))
        result = self.run_release(
            manifest_status=2, extra_args=["-o", str(output_file)]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)

    def test_malformed_existing_pin_is_treated_as_absent(self):
        # A pin file that parses as JSON but isn't an object (e.g. from a bad
        # manual edit or an unresolved merge) must not crash the resolver;
        # it should be treated the same as no pin existing yet.
        output_file = Path(self.tmp.name) / "manifest.json"
        output_file.write_text(json.dumps([1, 2, 3]))
        result = self.run_release(extra_args=["-o", str(output_file)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)

    def test_non_string_existing_version_is_treated_as_unreadable(self):
        # A "version" field that parses as JSON but isn't a string (e.g. an
        # unquoted number from a bad manual edit) must not crash the version
        # comparison; treat it the same as no readable pin.
        output_file = Path(self.tmp.name) / "manifest.json"
        output_file.write_text(json.dumps({"version": 2.1}))
        result = self.run_release(extra_args=["-o", str(output_file)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)

    def test_refuses_a_downgrade(self):
        output_file = Path(self.tmp.name) / "manifest.json"
        output_file.write_text(json.dumps(SAMPLE_MANIFEST))
        result = self.run_release(latest_body="2.1.279", extra_args=["-o", str(output_file)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        data = json.loads(output_file.read_text())
        self.assertEqual(data["version"], "2.1.280")

    def test_refuses_manifest_missing_target_platform(self):
        manifest = {"version": "2.1.280", "platforms": {"darwin-arm64": {"binary": "claude.zst", "checksum": "0" * 64}}}
        result = self.run_release(manifest_body=json.dumps(manifest))
        self.assertEqual(result.returncode, 1)
        self.assertIn("linux-x64", result.stderr)

    def test_refuses_manifest_missing_linux_arm64(self):
        manifest = {
            "version": "2.1.280",
            "platforms": {"linux-x64": SAMPLE_MANIFEST["platforms"]["linux-x64"]},
        }
        output_file = Path(self.tmp.name) / "manifest.json"
        result = self.run_release(
            manifest_body=json.dumps(manifest), extra_args=["-o", str(output_file)]
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("linux-arm64", result.stderr)
        self.assertFalse(output_file.exists())

    def test_refuses_linux_arm64_entry_without_a_checksum(self):
        manifest = json.loads(json.dumps(SAMPLE_MANIFEST))
        del manifest["platforms"]["linux-arm64"]["checksum"]
        result = self.run_release(manifest_body=json.dumps(manifest))
        self.assertEqual(result.returncode, 1)
        self.assertIn("linux-arm64", result.stderr)

    def test_latest_fetch_error_fails(self):
        result = self.run_release(latest_status=2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed with status 2", result.stderr)

    def test_manifest_fetch_error_fails(self):
        result = self.run_release(manifest_status=2)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed with status 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
