"""Drive opencode-release against fake GitHub release-list fixtures.

The helper's `curl` command is stubbed on `PATH` so these tests feed it a
fixture body instead of a network call.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/opencode-release"

LINUX_ASSET = "opencode-linux-x64.tar.gz"
DARWIN_ASSET = "opencode-darwin-arm64.zip"
LINUX_HEX = "563b5d663637226b6e3bb4bb6803281bc39b0d2cd88db06d674b6420aab009b0"
DARWIN_HEX = "31ab5a06a29edc7e49b895f35c2b64ebfe7c7f0437b0f2581b006efcd79fee1a"
OTHER_HEX = "9d10185acdb72336e086e699ca363a6065f410fd3c1caed0dc8046e95ac06ccb"

DEFAULT_URL = "https://api.github.com/repos/anomalyco/opencode/releases?per_page=100"


def asset(name, hex_digest):
    return {"name": name, "digest": f"sha256:{hex_digest}"}


def release(tag, linux_digest=None, linux_count=1, darwin_count=1, prerelease=False, draft=False):
    """Build one release object shaped like GitHub's REST API response.

    The linux tarball comes last, so a test can edit assets[-1].
    """
    assets = [
        asset("opencode-linux-x64-musl.tar.gz", OTHER_HEX),
        asset("opencode-linux-arm64.tar.gz", OTHER_HEX),
        asset("opencode-desktop-linux-x86_64.AppImage", OTHER_HEX),
        asset("SHA256SUMS", OTHER_HEX),
    ]
    for _ in range(darwin_count):
        assets.append(asset(DARWIN_ASSET, DARWIN_HEX))
    for _ in range(linux_count):
        entry = asset(LINUX_ASSET, LINUX_HEX)
        if linux_digest is not None:
            entry["digest"] = linux_digest
        assets.append(entry)
    return {"tag_name": tag, "prerelease": prerelease, "draft": draft, "assets": assets}


def releases(*items):
    return json.dumps(list(items))


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


FAKE_CURL = """#!{python}
import os, sys
expected = ['-sfL', '--max-time', '60', os.environ['FAKE_EXPECTED_URL']]
if sys.argv[1:] != expected:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}} != {{expected!r}}\\n')
    sys.exit(99)
status = int(os.environ.get('FAKE_STATUS', '0'))
if status:
    sys.exit(status)
sys.stdout.write(os.environ.get('FAKE_BODY', ''))
"""


class OpencodeReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.output = root / "opencode-release.json"

    def run_release(self, body, extra_args=None, status=0):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_EXPECTED_URL"] = DEFAULT_URL
        env["FAKE_BODY"] = body
        env["FAKE_STATUS"] = str(status)
        args = [sys.executable, str(SCRIPT)]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write_pin(self, version):
        self.output.write_text(json.dumps({"version": version, "platforms": {}}))

    def assert_refused(self, result, needle):
        self.assertEqual(result.returncode, 1)
        self.assertIn("opencode-release:", result.stderr)
        self.assertIn(needle, result.stderr)

    def test_writes_version_and_each_asset_digest_when_newer(self):
        self.write_pin("2.3.1")
        result = self.run_release(releases(release("v2.3.2")), ["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(
            json.loads(self.output.read_text()),
            {
                "version": "2.3.2",
                "platforms": {
                    "x86_64-linux": {"asset": LINUX_ASSET, "sha256": LINUX_HEX, "hash": sri(LINUX_HEX)},
                    "aarch64-darwin": {"asset": DARWIN_ASSET, "sha256": DARWIN_HEX, "hash": sri(DARWIN_HEX)},
                },
            },
        )

    def test_skips_other_majors_and_unrelated_tags_and_picks_the_highest_v2(self):
        body = releases(
            release("v3.0.0"),
            release("v1.19.6"),
            release("process-daemon-v0.6.0"),
            release("v2.3.2"),
            release("v2.3.10"),
            release("v2.3.1"),
        )
        result = self.run_release(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "2.3.10")

    def test_a_release_candidate_tag_is_never_resolved(self):
        body = releases(release("v2.4.0-rc1"), release("v2.3.2"))
        result = self.run_release(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "2.3.2")

    def test_a_corrupt_pin_file_is_replaced_by_the_resolved_release(self):
        self.output.write_text("not json")
        result = self.run_release(releases(release("v2.3.2")), ["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "2.3.2")

    def test_skips_a_v2_prerelease_and_a_v2_draft(self):
        body = releases(
            release("v2.4.0", prerelease=True),
            release("v2.3.9", draft=True),
            release("v2.3.2"),
        )
        result = self.run_release(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "2.3.2")

    def test_refuses_when_no_v2_release_is_listed(self):
        result = self.run_release(releases(release("v1.19.6"), release("process-daemon-v0.6.0")))
        self.assert_refused(result, "no stable v2 release")

    def test_equal_or_older_version_leaves_the_pin_untouched(self):
        for pinned in ("2.3.2", "2.4.0"):
            with self.subTest(pinned=pinned):
                self.write_pin(pinned)
                before = self.output.read_bytes()
                result = self.run_release(releases(release("v2.3.2")), ["-o", str(self.output)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already up to date", result.stdout)
                self.assertEqual(self.output.read_bytes(), before)

    def test_missing_asset_refuses_and_keeps_the_previous_pin(self):
        self.write_pin("2.3.1")
        before = self.output.read_bytes()
        result = self.run_release(releases(release("v2.3.2", darwin_count=0)), ["-o", str(self.output)])
        self.assertEqual(result.returncode, 1)
        self.assertIn(DARWIN_ASSET, result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_duplicate_asset_refuses(self):
        result = self.run_release(releases(release("v2.3.2", linux_count=2)))
        self.assert_refused(result, LINUX_ASSET)

    def test_invalid_digest_refuses(self):
        result = self.run_release(releases(release("v2.3.2", linux_digest="sha1:abc")))
        self.assert_refused(result, "invalid sha256 digest")

    def test_curl_failure_and_non_json_refuse(self):
        self.assert_refused(self.run_release("", status=22), "failed")
        self.assert_refused(self.run_release("not json"), "not JSON")


if __name__ == "__main__":
    unittest.main()
