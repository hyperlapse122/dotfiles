import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/t3code-release"

FAKE_TOKEN = "ghp_fake0000000000000000000000000000test"

APPIMAGE_X64_HEX = "7521793d4dc87f2b985f88b48b070bedf33a1f590cca34a96c9e7ca0b1fe298b"
APPIMAGE_ARM_HEX = "784939b3fc0aec185df9148893c22b0ae10abb6e32d03905474c5a43ba511508"
CLI_ARM_HEX = "73f03e41f2173a9695bb60e2867f14133cf396e0340af6cc8e0ceecd4efcd7d4"
ZIP_DARWIN_HEX = "d576a1481c61ff800d013f33295518794c8675da1d30b945dc7c0b587cfdfee5"
CLI_DARWIN_HEX = "02c191e2a3ed5c3d8c9808d6039884cda18e72426130d062bfbd1b024a5dc3fe"
OTHER_HEX = "6ec2232f168c00aa108c04218e92666a7df2f4c2b71c1e93c734294ae71359d0"


CLI_X64_HEX = "1234" * 16


def target_assets(version):
    return {
        "x86_64-linux": {
            "desktop": (f"T3-Code-{version}-x86_64.AppImage", APPIMAGE_X64_HEX),
            "cli": (f"t3-{version}-linux-x64.tar.gz", CLI_X64_HEX),
        },
        "aarch64-linux": {
            "desktop": (f"T3-Code-{version}-arm64.AppImage", APPIMAGE_ARM_HEX),
            "cli": (f"t3-{version}-linux-arm64.tar.gz", CLI_ARM_HEX),
        },
        "aarch64-darwin": {
            "desktop": (f"T3-Code-{version}-arm64.zip", ZIP_DARWIN_HEX),
            "cli": (f"t3-{version}-darwin-arm64.tar.gz", CLI_DARWIN_HEX),
        },
    }


def asset(name, hex_digest):
    return {
        "name": name,
        "digest": f"sha256:{hex_digest}",
        "browser_download_url": f"https://github.com/pingdotgg/t3code/releases/download/x/{name}",
    }


def release(tag, prerelease=False, draft=False, omit=(), duplicate=(), digests=None):
    """Build one release object shaped like GitHub's REST API response."""
    version = tag[1:]
    assets = [
        asset(f"T3-Code-{version}-amd64.deb", OTHER_HEX),
        asset(f"T3-Code-{version}-arm64.zip.blockmap", OTHER_HEX),
        asset(f"t3-{version}-win32-arm64.zip", OTHER_HEX),
        asset("SHA256SUMS", OTHER_HEX),
    ]
    for components in target_assets(version).values():
        for name, hex_digest in components.values():
            if name in omit:
                continue
            entry = asset(name, hex_digest)
            if digests and name in digests:
                entry["digest"] = digests[name]
            assets.append(entry)
            if name in duplicate:
                assets.append(asset(name, hex_digest))
    return {"tag_name": tag, "prerelease": prerelease, "draft": draft, "assets": assets}


DEFAULT_LIST_URL = "https://api.github.com/repos/pingdotgg/t3code/releases?per_page=50"

NEWEST = "v0.0.47"
NEWEST_VERSION = NEWEST[1:]
OLDER_VERSION = "0.0.46"


def release_list(newest=None):
    """An older stable, then a newer preview, nightly, and Android build, newest stable last."""
    newest = newest if newest is not None else release(NEWEST)
    return json.dumps(
        [
            release(f"v{OLDER_VERSION}"),
            release("v0.0.48-preview.20261005.2700", prerelease=True),
            release("v0.0.48-nightly.20261009.3000", prerelease=True),
            release("t3code-android-internal-2.3.0-78", prerelease=True),
            newest,
        ]
    )


def expected_pin(tag):
    version = tag[1:]
    return {
        "version": version,
        "tag": tag,
        "platforms": {
            system: {
                component: {"asset": name, "sha256": hex_digest, "hash": sri(hex_digest)}
                for component, (name, hex_digest) in components.items()
            }
            for system, components in target_assets(version).items()
        },
    }


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


FAKE_CURL = """#!{python}
import json, os, sys
if sys.argv[1:6] != ['-sfL', '--max-time', '60', '-H', '@-'] or len(sys.argv) != 7:
    sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}}\\n')
    sys.exit(99)
with open(os.environ['FAKE_STDIN_LOG'], 'a') as f:
    f.write(json.dumps(sys.stdin.read()) + '\\n')
with open(os.environ['FAKE_ARGS_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
status = int(os.environ.get('FAKE_STATUS', '0'))
if status:
    sys.exit(status)
sys.stdout.write(os.environ.get('FAKE_BODY', ''))
"""


class T3codeReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        curl = self.bin_dir / "curl"
        curl.write_text(FAKE_CURL.format(python=sys.executable))
        curl.chmod(0o755)
        self.stdin_log = root / "stdin.log"
        self.args_log = root / "args.log"
        self.output = root / "t3code-release.json"

    def run_release(self, body=None, extra_args=None, status=0, token=None):
        if body is None:
            body = release_list()
        env = dict(os.environ)
        env.pop("GH_TOKEN", None)
        if token is not None:
            env["GH_TOKEN"] = token
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_BODY"] = body
        env["FAKE_STATUS"] = str(status)
        env["FAKE_STDIN_LOG"] = str(self.stdin_log)
        env["FAKE_ARGS_LOG"] = str(self.args_log)
        args = [sys.executable, str(SCRIPT)]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def fetched_urls(self):
        if not self.args_log.exists():
            return []
        return [json.loads(line)[-1] for line in self.args_log.read_text().splitlines()]

    def write_pin(self, version):
        self.output.write_text(json.dumps({"version": version, "tag": f"v{version}"}))

    def assert_refused(self, result, needle):
        self.assertEqual(result.returncode, 1)
        self.assertIn("t3code-release:", result.stderr)
        self.assertIn(needle, result.stderr)
        self.assertFalse(self.output.exists())

    def test_picks_the_newest_stable_over_preview_nightly_and_android_builds(self):
        self.write_pin(OLDER_VERSION)
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(json.loads(self.output.read_text()), expected_pin(NEWEST))

    def test_refuses_a_release_missing_the_arm64_appimage(self):
        name = f"T3-Code-{NEWEST_VERSION}-arm64.AppImage"
        body = release_list(release(NEWEST, omit=(name,)))
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assert_refused(result, name)

    def test_refuses_a_release_missing_a_darwin_asset(self):
        for name in [
            f"T3-Code-{NEWEST_VERSION}-arm64.zip",
            f"t3-{NEWEST_VERSION}-darwin-arm64.tar.gz",
        ]:
            with self.subTest(missing=name):
                body = release_list(release(NEWEST, omit=(name,)))
                result = self.run_release(body=body, extra_args=["-o", str(self.output)])
                self.assert_refused(result, name)

    def test_refuses_a_release_with_a_duplicated_asset(self):
        name = f"t3-{NEWEST_VERSION}-linux-x64.tar.gz"
        body = release_list(release(NEWEST, duplicate=(name,)))
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assert_refused(result, name)

    def test_refuses_a_digest_that_is_not_sha256(self):
        name = f"t3-{NEWEST_VERSION}-linux-arm64.tar.gz"
        for digest in ["sha512:" + CLI_ARM_HEX, "sha256:abc123", CLI_ARM_HEX, None]:
            with self.subTest(digest=digest):
                body = release_list(release(NEWEST, digests={name: digest}))
                result = self.run_release(body=body, extra_args=["-o", str(self.output)])
                self.assert_refused(result, "digest")

    def test_current_pin_at_newest_version_writes_nothing(self):
        self.output.write_text(json.dumps(expected_pin(NEWEST)))
        before = self.output.read_bytes()
        desktop = f"T3-Code-{NEWEST_VERSION}-x86_64.AppImage"
        for digests in ({}, {desktop: "sha256:" + OTHER_HEX}):
            with self.subTest(digests=digests):
                body = release_list(release(NEWEST, digests=digests))
                result = self.run_release(body=body, extra_args=["-o", str(self.output)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already up to date", result.stdout)
                self.assertEqual(self.output.read_bytes(), before)

    def test_a_newer_stable_pin_is_not_downgraded(self):
        for version in ("0.1.7", "0.0.48"):
            with self.subTest(version=version):
                self.write_pin(version)
                before = self.output.read_bytes()
                result = self.run_release(extra_args=["-o", str(self.output)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("already up to date", result.stdout)
                self.assertEqual(self.output.read_bytes(), before)

    def test_a_nightly_pin_is_replaced_by_the_stable_release(self):
        # Moving off the nightly track: the pin's base version is higher, but a
        # tag that is not plain semver counts as older than any stable release.
        self.write_pin("0.0.48-nightly.20261010.4491")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), expected_pin(NEWEST))

    def test_selection_compares_versions_not_list_order(self):
        body = json.dumps([release(NEWEST), release("v0.0.9"), release("v0.0.46")])
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], NEWEST)

    def test_ignores_drafts_and_plain_tags_marked_prerelease(self):
        body = json.dumps(
            [
                release("v0.0.48", draft=True),
                release("v0.0.49", prerelease=True),
                release(NEWEST),
            ]
        )
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], NEWEST)

    def test_ignores_tags_that_are_not_plain_semver(self):
        body = json.dumps(
            [
                release("v0.0.48-rc.1"),
                release("v0.0.49-nightly.20261009.3000"),
                release("0.0.48"),
                release("v0.1"),
                release("v1.0.0.1"),
                release(NEWEST),
            ]
        )
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], NEWEST)

    def test_refuses_a_list_without_a_stable_release(self):
        body = json.dumps(
            [
                release("v0.0.47-nightly.20261009.3000", prerelease=True),
                release("v0.0.47-preview.20261005.2700", prerelease=True),
                release("v0.0.48", prerelease=True),
            ]
        )
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assert_refused(result, "no stable release")

    def test_malformed_existing_pin_is_treated_as_absent(self):
        self.output.write_text("{not json")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], NEWEST_VERSION)

    def test_refuses_a_body_that_is_not_a_list(self):
        for body in ["<html>rate limited</html>", json.dumps({"message": "API rate limit"})]:
            with self.subTest(body=body):
                result = self.run_release(body=body, extra_args=["-o", str(self.output)])
                self.assert_refused(result, "release list")

    def test_fetch_error_fails_naming_the_url(self):
        result = self.run_release(status=22, extra_args=["-o", str(self.output)])
        self.assert_refused(result, "releases?per_page=50 failed with status 22")

    def test_dry_run_prints_json_and_writes_nothing(self):
        result = self.run_release(extra_args=["--dry-run", "-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), expected_pin(NEWEST))
        self.assertFalse(self.output.exists())

    def test_source_url_is_passed_as_the_last_argument(self):
        url = "https://example.invalid/releases?per_page=5"
        result = self.run_release(extra_args=["--dry-run", "--source-url", url])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fetched_urls()[0], url)

    def test_gh_token_is_sent_on_stdin_as_a_bearer_header(self):
        result = self.run_release(token=FAKE_TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        stdins = [json.loads(line) for line in self.stdin_log.read_text().splitlines()]
        self.assertEqual(stdins, [f"Authorization: Bearer {FAKE_TOKEN}\n"])
        self.assertNotIn(FAKE_TOKEN, self.args_log.read_text())

    def test_no_header_without_gh_token(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        stdins = [json.loads(line) for line in self.stdin_log.read_text().splitlines()]
        self.assertEqual(stdins, [""])

    def test_fetch_failure_does_not_print_the_token(self):
        result = self.run_release(status=22, token=FAKE_TOKEN)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(FAKE_TOKEN, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
