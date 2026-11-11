"""Drive pi-release against a fake GitHub release and SHA256SUMS.

The helper's network calls go through an overridable command, so these tests
serve each URL from a fixture directory instead of the network.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/pi-release"
SOURCE_URL = "https://api.github.com/repos/earendil-works/pi/releases/latest"

DIGESTS = {
    "pi-linux-x64.tar.gz": "f2e4e4329603223d03260cdb8bd5033dbdc1f73ba58ab8939db2e56546e115d2",
    "pi-linux-arm64.tar.gz": "fa5829c7ef83ffeaebba015715c8306220f89b2aa8a00154efbba98dd5440156",
    "pi-darwin-arm64.tar.gz": "79d9979d76a2a5adb7c28e27e9b44629928ccd0dc9fbb6ae7217860bd5e8be5d",
    "pi-darwin-x64.tar.gz": "1bdefc9e1074c1de458ea9f2e43e6013ce49cd05326009b3de144037036585e2",
}
SYSTEMS = {
    "x86_64-linux": "pi-linux-x64.tar.gz",
    "aarch64-linux": "pi-linux-arm64.tar.gz",
    "aarch64-darwin": "pi-darwin-arm64.tar.gz",
}
SOURCE_REVISION = '1234567890abcdef1234567890abcdef12345678'
SOURCE_HASH = '0' * 52


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


def download(tag, name):
    return f"https://github.com/earendil-works/pi/releases/download/{tag}/{name}"


def release(tag="v1.4.0", digests=None, drop=(), api_digests=None, **fields):
    """Build a latest-release document shaped like the GitHub API's."""
    digests = DIGESTS if digests is None else digests
    api_digests = digests if api_digests is None else api_digests
    assets = [{"name": "SHA256SUMS", "browser_download_url": download(tag, "SHA256SUMS")}]
    for name in digests:
        if name in drop:
            continue
        asset = {"name": name, "browser_download_url": download(tag, name)}
        if name in api_digests:
            asset["digest"] = f"sha256:{api_digests[name]}"
        assets.append(asset)
    doc = {"tag_name": tag, "draft": False, "prerelease": False, "assets": assets}
    doc.update(fields)
    return doc


def sums(digests=None, extra=()):
    """Build a SHA256SUMS body; upstream repeats the linux-x64 line."""
    digests = DIGESTS if digests is None else digests
    lines = [f"{digest}  {name}" for name, digest in digests.items()]
    lines.append(f"{DIGESTS['pi-linux-x64.tar.gz']}  pi-linux-x64.tar.gz")
    lines.extend(extra)
    return "\n".join(lines) + "\n"


# Serves a URL from FAKE_DIR, keyed by its last path segment.
FAKE_FETCH = "#!" + sys.executable + "\n" + """import os, sys
path = os.path.join(os.environ['FAKE_DIR'], sys.argv[-1].rsplit('/', 1)[-1])
if not os.path.exists(path):
    sys.exit(22)
sys.stdout.write(open(path).read())
"""


class PiReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.fetch = root / "curl"
        self.fetch.write_text(FAKE_FETCH)
        self.fetch.chmod(0o755)
        prefetch = root / 'nix-prefetch-url'
        prefetch.write_text(FAKE_FETCH)
        prefetch.chmod(0o755)
        self.served = root / "served"
        self.served.mkdir()
        self.output = root / "pi-release.json"

    def serve(self, doc=None, body=None):
        if doc is not None:
            (self.served / "latest").write_text(json.dumps(doc))
            tag = doc.get('tag_name', '')
            if '/' not in tag:
                (self.served / tag).write_text(json.dumps({'sha': SOURCE_REVISION}))
            (self.served / (SOURCE_REVISION + '.tar.gz')).write_text(SOURCE_HASH)
        if body is not None:
            (self.served / "SHA256SUMS").write_text(body)

    def run_release(self, extra_args=None):
        env = dict(os.environ)
        env["PATH"] = str(self.fetch.parent) + os.pathsep + os.environ["PATH"]
        env["FAKE_DIR"] = str(self.served)
        args = [sys.executable, str(SCRIPT), "--source-url", SOURCE_URL]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, env=env, capture_output=True, text=True)

    def assert_refused(self, message):
        self.output.write_text("sentinel\n")
        proc = self.run_release(["--output", str(self.output)])
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn(message, proc.stderr)
        self.assertEqual(self.output.read_text(), "sentinel\n")

    def test_writes_a_pin_from_a_release_whose_assets_match_sha256sums(self):
        self.serve(release(), sums())
        proc = self.run_release(["--output", str(self.output)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        pin = json.loads(self.output.read_text())
        self.assertEqual(pin["version"], "1.4.0")
        self.assertEqual(pin['source'], {'rev': SOURCE_REVISION, 'sha256': SOURCE_HASH})
        self.assertEqual(
            pin["platforms"],
            {
                system: {"url": download("v1.4.0", name), "hash": sri(DIGESTS[name])}
                for system, name in SYSTEMS.items()
            },
        )

    def test_accepts_a_release_whose_assets_carry_no_api_digest(self):
        self.serve(release(api_digests={}), sums())
        proc = self.run_release()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["version"], "1.4.0")

    def test_refuses_an_api_digest_that_differs_from_sha256sums(self):
        wrong = dict(DIGESTS, **{"pi-linux-arm64.tar.gz": "0" * 64})
        self.serve(release(api_digests=wrong), sums())
        self.assert_refused("pi-linux-arm64.tar.gz has digest")

    def test_refuses_a_sha256sums_that_lists_one_tarball_twice_with_different_digests(self):
        self.serve(release(), sums(extra=[f"{'1' * 64}  pi-darwin-arm64.tar.gz"]))
        self.assert_refused("two different digests")

    def test_refuses_a_release_missing_a_target_tarball(self):
        for name in SYSTEMS.values():
            with self.subTest(name=name):
                self.serve(release(drop=(name,)), sums())
                self.assert_refused(f"has no {name}")

    def test_refuses_a_sha256sums_missing_a_target_tarball(self):
        listed = {k: v for k, v in DIGESTS.items() if k != "pi-darwin-arm64.tar.gz"}
        self.serve(release(), sums(digests=listed))
        self.assert_refused("lists no pi-darwin-arm64.tar.gz")

    def test_refuses_a_release_without_sha256sums(self):
        doc = release()
        doc["assets"] = [a for a in doc["assets"] if a["name"] != "SHA256SUMS"]
        self.serve(doc, sums())
        self.assert_refused("has no SHA256SUMS")

    def test_refuses_a_download_url_outside_the_release(self):
        doc = release()
        for asset in doc["assets"]:
            if asset["name"] == "pi-linux-x64.tar.gz":
                asset["browser_download_url"] = "https://example.com/pi-linux-x64.tar.gz"
        self.serve(doc, sums())
        self.assert_refused("downloads from 'https://example.com/pi-linux-x64.tar.gz'")

    def test_refuses_a_malformed_checksum(self):
        self.serve(release(api_digests={}), sums(extra=["xyz  pi-linux-x64.tar.gz"]))
        self.assert_refused("invalid sha256")

    def test_refuses_a_non_plain_version(self):
        for tag in ("v1.5.0-beta.1", "1.5.0", "nightly"):
            with self.subTest(tag=tag):
                self.serve(release(tag=tag), sums())
                self.assert_refused("not v and a plain version string")

    def test_refuses_a_draft_or_prerelease(self):
        for field in ("draft", "prerelease"):
            with self.subTest(field=field):
                self.serve(release(**{field: True}), sums())
                self.assert_refused("draft or prerelease")

    def test_same_version_leaves_the_pin_byte_identical(self):
        self.serve(release(), sums())
        existing = '{"version": "1.4.0", "platforms": {}}\n'
        self.output.write_text(existing)
        proc = self.run_release(["--output", str(self.output)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("already up to date", proc.stdout)
        self.assertEqual(self.output.read_text(), existing)

    def test_refuses_a_downgrade(self):
        self.serve(release(), sums())
        existing = '{"version": "1.10.0", "platforms": {}}\n'
        self.output.write_text(existing)
        proc = self.run_release(["--output", str(self.output)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.output.read_text(), existing)

    def test_a_newer_version_replaces_the_pin(self):
        self.serve(release(tag="v1.10.0"), sums())
        self.output.write_text('{"version": "1.9.0", "platforms": {}}\n')
        proc = self.run_release(["--output", str(self.output)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "1.10.0")

    def test_refuses_a_latest_release_that_is_not_json_or_not_an_object(self):
        for body, message in (
            ("<html>rate limited</html>", "is not JSON"),
            ("", "is not JSON"),
            ("[]", "is not a JSON object"),
            ('"v1.4.0"', "is not a JSON object"),
            ("null", "is not a JSON object"),
        ):
            with self.subTest(body=body):
                (self.served / "latest").write_text(body)
                self.assert_refused(f"response from {SOURCE_URL} {message}")

    def test_a_pin_whose_version_does_not_parse_is_replaced(self):
        self.serve(release(), sums())
        for existing in (
            '{"version": "1.x", "platforms": {}}\n',
            '{"version": "nightly"}\n',
            '{"version": 3}\n',
            '{"version": ["1", "4"]}\n',
            "not json\n",
        ):
            with self.subTest(existing=existing):
                self.output.write_text(existing)
                proc = self.run_release(["--output", str(self.output)])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn("updated", proc.stdout)
                self.assertEqual(json.loads(self.output.read_text())["version"], "1.4.0")

    def test_fetch_error_names_the_url(self):
        proc = self.run_release()
        self.assertEqual(proc.returncode, 1)
        self.assertIn(f"fetching {SOURCE_URL} failed", proc.stderr)

    def test_refuses_a_missing_source_revision(self):
        self.serve(release(), sums())
        (self.served / 'v1.4.0').write_text('{}')
        self.assert_refused('contains no source revision')

    def test_refuses_an_invalid_source_revision(self):
        self.serve(release(), sums())
        (self.served / 'v1.4.0').write_text('{"sha":"main"}')
        self.assert_refused('contains an invalid source revision')

    def test_source_hash_failure_preserves_the_pin(self):
        self.serve(release(), sums())
        (self.served / (SOURCE_REVISION + '.tar.gz')).unlink()
        self.assert_refused('cannot hash Pi source archive')

    def test_dry_run_prints_json_and_writes_nothing(self):
        self.serve(release(), sums())
        proc = self.run_release(["--dry-run", "--output", str(self.output)])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["version"], "1.4.0")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
