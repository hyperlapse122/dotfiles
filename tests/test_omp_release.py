"""Drive omp-release against fake GitHub API fixtures.

The helper's `curl` command is stubbed on `PATH` so these tests feed it fixture
bodies keyed by URL instead of making network calls.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/omp-release"

API = "https://api.github.com/repos/can1357/oh-my-pi"
LATEST_URL = f"{API}/releases/latest"

LINUX_ASSET = "omp-linux-x64"
DARWIN_ASSET = "omp-darwin-arm64"
LINUX_HEX = "04e9490f9394da6d6804474cc2e41eb3d18f8e26215df4b34bdd4ad4c0d8a401"
DARWIN_HEX = "d5a3324acd98375a01698a1b0c018be48caed2956c8aa9044ad137fe43bc0400"
OTHER_HEX = "3b4f4a360e9c4c274d50b84fcbc7e77d8ab482d1661d5998a49eaaf5f0183c02"
REV = "31ffee513f27a01bba7d4dfbe12bae239cdc646a"


def asset(name, hex_digest):
    return {"name": name, "digest": f"sha256:{hex_digest}"}


def release(tag, linux_count=1, darwin_count=1, linux_digest=None, prerelease=False, draft=False):
    """One release object shaped like GitHub's REST API response."""
    assets = [
        asset("omp-linux-musl-x64", OTHER_HEX),
        asset("omp-darwin-x64", OTHER_HEX),
        asset("SHA256SUMS.txt", OTHER_HEX),
    ]
    assets += [asset(DARWIN_ASSET, DARWIN_HEX)] * darwin_count
    for _ in range(linux_count):
        entry = asset(LINUX_ASSET, LINUX_HEX)
        if linux_digest is not None:
            entry["digest"] = linux_digest
        assets.append(entry)
    return {
        "tag_name": tag,
        "target_commitish": "main",
        "prerelease": prerelease,
        "draft": draft,
        "assets": assets,
    }


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


FAKE_CURL = """#!{python}
import json, os, sys
args = sys.argv[1:]
if args[:3] != ['-sfL', '--max-time', '60'] or len(args) != 4:
    sys.stderr.write(f'unexpected curl argv: {{args!r}}\\n')
    sys.exit(99)
responses = json.loads(os.environ['FAKE_RESPONSES'])
if args[3] not in responses:
    sys.exit(22)
sys.stdout.write(responses[args[3]])
"""


class OmpReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.output = root / "omp-release.json"

    def run_release(self, latest, commit_sha=REV, extra_args=None):
        responses = {}
        if latest is not None:
            responses[LATEST_URL] = latest if isinstance(latest, str) else json.dumps(latest)
            tag = latest.get("tag_name") if isinstance(latest, dict) else None
            if tag and commit_sha is not None:
                responses[f"{API}/commits/{tag}"] = json.dumps({"sha": commit_sha})
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_RESPONSES"] = json.dumps(responses)
        args = [sys.executable, str(SCRIPT)]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def write_pin(self, version):
        self.output.write_text(json.dumps({"version": version, "rev": "0" * 40, "platforms": {}}))

    def assert_refused(self, result, needle):
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("omp-release:", result.stderr)
        self.assertIn(needle, result.stderr)

    def test_writes_version_rev_and_each_asset_digest_when_newer(self):
        self.write_pin("19.1.0")
        result = self.run_release(release("v19.1.1"), extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(
            json.loads(self.output.read_text()),
            {
                "version": "19.1.1",
                "rev": REV,
                "platforms": {
                    "x86_64-linux": {"asset": LINUX_ASSET, "sha256": LINUX_HEX, "hash": sri(LINUX_HEX)},
                    "aarch64-darwin": {"asset": DARWIN_ASSET, "sha256": DARWIN_HEX, "hash": sri(DARWIN_HEX)},
                },
            },
        )

    def test_dry_run_prints_the_pin_without_writing(self):
        self.write_pin("19.1.0")
        before = self.output.read_bytes()
        result = self.run_release(release("v19.1.1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["rev"], REV)
        self.assertEqual(self.output.read_bytes(), before)

    def test_equal_or_older_version_leaves_the_pin_untouched(self):
        for pinned in ("19.1.1", "19.2.0"):
            with self.subTest(pinned=pinned):
                self.write_pin(pinned)
                before = self.output.read_bytes()
                result = self.run_release(release("v19.1.1"), extra_args=["-o", str(self.output)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already up to date", result.stdout)
                self.assertEqual(self.output.read_bytes(), before)

    def test_missing_or_duplicate_asset_refuses_and_keeps_the_pin(self):
        for latest, name in (
            (release("v19.1.1", darwin_count=0), DARWIN_ASSET),
            (release("v19.1.1", linux_count=2), LINUX_ASSET),
        ):
            with self.subTest(name=name):
                self.write_pin("19.1.0")
                before = self.output.read_bytes()
                result = self.run_release(latest, extra_args=["-o", str(self.output)])
                self.assert_refused(result, name)
                self.assertEqual(self.output.read_bytes(), before)

    def test_invalid_digest_refuses(self):
        result = self.run_release(release("v19.1.1", linux_digest="sha1:abc"))
        self.assert_refused(result, "invalid sha256 digest")

    def test_prerelease_draft_and_non_release_tags_refuse(self):
        for latest in (
            release("v19.2.0", prerelease=True),
            release("v19.2.0", draft=True),
            release("v19.2.0-rc1"),
        ):
            with self.subTest(tag=latest["tag_name"], pre=latest["prerelease"], draft=latest["draft"]):
                self.assert_refused(self.run_release(latest), "stable")

    def test_unusable_commit_sha_refuses(self):
        self.assert_refused(self.run_release(release("v19.1.1"), commit_sha="main"), "commit")
        self.assert_refused(self.run_release(release("v19.1.1"), commit_sha=None), "failed")

    def test_fetch_failure_and_non_json_refuse(self):
        self.assert_refused(self.run_release(None), "failed")
        self.assert_refused(self.run_release("not json"), "not JSON")


if __name__ == "__main__":
    unittest.main()
