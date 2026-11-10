import base64
import gzip
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/t3code-release"

FAKE_TOKEN = "ghp_fake0000000000000000000000000000test"

APPIMAGE_X64_HEX = "7521793d4dc87f2b985f88b48b070bedf33a1f590cca34a96c9e7ca0b1fe298b"
APPIMAGE_ARM_HEX = "784939b3fc0aec185df9148893c22b0ae10abb6e32d03905474c5a43ba511508"
CLI_ARM_HEX = "73f03e41f2173a9695bb60e2867f14133cf396e0340af6cc8e0ceecd4efcd7d4"
ZIP_DARWIN_HEX = "d576a1481c61ff800d013f33295518794c8675da1d30b945dc7c0b587cfdfee5"
CLI_DARWIN_HEX = "02c191e2a3ed5c3d8c9808d6039884cda18e72426130d062bfbd1b024a5dc3fe"
OTHER_HEX = "6ec2232f168c00aa108c04218e92666a7df2f4c2b71c1e93c734294ae71359d0"


ACP_PREFIX = "https://dl.google.com/agy-extensions/releases/"
ACP_ENTRIES = {
    "darwin-arm64": ("macos", "darwin-arm64", "a1" * 32, 111, 222, 333),
    "darwin-x64": ("macos", "darwin-x86_64", "b2" * 32, 112, 223, 334),
    "linux-x64": ("linux", "linux-x86_64", "c3" * 32, 113, 224, 335),
    "linux-arm64": ("linux", "linux-arm64", "d4" * 32, 114, 225, 336),
    "win32-x64": ("windows", "windows-x86_64", "e5" * 32, 115, 226, 337),
}


def acp_table(version="1.4.0", url_prefix=ACP_PREFIX, keys=None, variable="releaseAssets"):
    """Render the bundler's `releaseAssets` literal the way the CLI embeds it."""
    entries = []
    for key, (directory, suffix, sha, archive, exe, harness) in ACP_ENTRIES.items():
        if keys is not None and key not in keys:
            continue
        entries.append(
            f'\t\t["{key}", {{\n\t\t\tversion: ANTIGRAVITY_RELEASE_VERSION,\n'
            f'\t\t\turl: "{url_prefix}{directory}/agy-acp-server-{version}-{suffix}.zip",\n'
            f'\t\t\tsha256: "{sha}",\n\t\t\tarchiveBytes: {archive},\n'
            f'\t\t\texecutable: {{\n\t\t\t\tname: "agy_acp_server.par",\n\t\t\t\tbytes: {exe}\n\t\t\t}},\n'
            f'\t\t\tharness: {{\n\t\t\t\tname: "localharness_external",\n\t\t\t\tbytes: {harness}\n\t\t\t}}\n\t\t}}]'
        )
    return (
        f'var ANTIGRAVITY_RELEASE_VERSION, {variable};\n'
        f'\tANTIGRAVITY_RELEASE_VERSION = "{version}";\n'
        f'\t{variable} = /* @__PURE__ */ new Map([\n' + ",\n".join(entries) + "\n\t]);\n"
    )


def cli_tarball(table):
    """A CLI tarball whose `t3` binary embeds the given table among other bytes."""
    binary = b"\x7fELF\x00junk" + table.encode() + b"\x00trailing"
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        info = tarfile.TarInfo("t3-x/t3")
        info.size = len(binary)
        info.mtime = 0
        tar.addfile(info, io.BytesIO(binary))
    return gzip.compress(raw.getvalue(), mtime=0)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


DEFAULT_TARBALL = cli_tarball(acp_table())
CLI_X64_HEX = sha256_hex(DEFAULT_TARBALL)


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


def release(tag, prerelease=True, draft=False, omit=(), duplicate=(), digests=None):
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

NEWEST = "v0.0.46-nightly.20261004.2644"
NEWEST_VERSION = NEWEST[1:]


def release_list(newest=None):
    """A stable, a newer preview, and two nightlies, newest nightly not first."""
    newest = newest if newest is not None else release(NEWEST)
    return json.dumps(
        [
            release("v0.0.47-preview.20261005.2700"),
            release("v0.0.46-nightly.20261003.2638"),
            release("v0.0.47", prerelease=False),
            newest,
        ]
    )


def expected_antigravity(version="1.4.0"):
    section = {}
    for system, key in {
        "x86_64-linux": "linux-x64",
        "aarch64-linux": "linux-arm64",
        "aarch64-darwin": "darwin-arm64",
    }.items():
        directory, suffix, sha, archive, exe, harness = ACP_ENTRIES[key]
        section[system] = {
            "platform": key,
            "version": version,
            "url": f"{ACP_PREFIX}{directory}/agy-acp-server-{version}-{suffix}.zip",
            "sha256": sha,
            "hash": sri(sha),
            "archiveBytes": archive,
            "executable": {"name": "agy_acp_server.par", "bytes": exe},
            "harness": {"name": "localharness_external", "bytes": harness},
        }
    return section


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
        "antigravity": expected_antigravity(),
    }


def sri(hex_digest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_digest)).decode("ascii")


FAKE_CURL = """#!{python}
import json, os, sys
if '-o' in sys.argv:
    # An asset download: -sfL --max-time N -o DEST URL
    if sys.argv[1:4] != ['-sfL', '--max-time', '900'] or sys.argv[4] != '-o' or len(sys.argv) != 7:
        sys.stderr.write(f'unexpected curl argv: {{sys.argv[1:]!r}}\\n')
        sys.exit(99)
    with open(os.environ['FAKE_ARGS_LOG'], 'a') as f:
        f.write(json.dumps(sys.argv[1:]) + '\\n')
    with open(os.environ['FAKE_TARBALL'], 'rb') as src, open(sys.argv[5], 'wb') as dst:
        dst.write(src.read())
    sys.exit(0)
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

    def run_release(self, body=None, extra_args=None, status=0, token=None, tarball=None):
        if body is None:
            body = release_list()
        env = dict(os.environ)
        env.pop("GH_TOKEN", None)
        if token is not None:
            env["GH_TOKEN"] = token
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        env["FAKE_BODY"] = body
        env["FAKE_STATUS"] = str(status)
        tarball_path = Path(self.tmp.name) / "cli.tar.gz"
        tarball_path.write_bytes(DEFAULT_TARBALL if tarball is None else tarball)
        env["FAKE_TARBALL"] = str(tarball_path)
        env["FAKE_STDIN_LOG"] = str(self.stdin_log)
        env["FAKE_ARGS_LOG"] = str(self.args_log)
        args = [sys.executable, str(SCRIPT)]
        args.extend(extra_args if extra_args is not None else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, env=env)

    def fetched_urls(self):
        if not self.args_log.exists():
            return []
        return [json.loads(line)[-1] for line in self.args_log.read_text().splitlines()]

    def write_pin(self, version, antigravity=None):
        payload = {"version": version, "tag": f"v{version}"}
        if antigravity is not None:
            payload["antigravity"] = antigravity
        self.output.write_text(json.dumps(payload))

    def assert_refused(self, result, needle):
        self.assertEqual(result.returncode, 1)
        self.assertIn("t3code-release:", result.stderr)
        self.assertIn(needle, result.stderr)
        self.assertFalse(self.output.exists())

    def test_picks_the_newest_nightly_over_stable_and_preview(self):
        self.write_pin("0.0.45-nightly.20261001.1000")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        self.assertEqual(json.loads(self.output.read_text()), expected_pin(NEWEST))
    def test_refuses_a_nightly_missing_the_arm64_appimage(self):
        name = f"T3-Code-{NEWEST_VERSION}-arm64.AppImage"
        body = release_list(release(NEWEST, omit=(name,)))
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assert_refused(result, name)

    def test_refuses_a_nightly_missing_a_darwin_asset(self):
        for name in [
            f"T3-Code-{NEWEST_VERSION}-arm64.zip",
            f"t3-{NEWEST_VERSION}-darwin-arm64.tar.gz",
        ]:
            with self.subTest(missing=name):
                body = release_list(release(NEWEST, omit=(name,)))
                result = self.run_release(body=body, extra_args=["-o", str(self.output)])
                self.assert_refused(result, name)

    def test_refuses_a_nightly_with_a_duplicated_asset(self):
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

    def test_current_pin_equal_to_newest_writes_nothing(self):
        self.write_pin(NEWEST_VERSION, antigravity=expected_antigravity())
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_unchanged_version_without_an_antigravity_section_writes_it(self):
        self.write_pin(NEWEST_VERSION)
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), expected_pin(NEWEST))

    def test_unchanged_version_with_a_stale_antigravity_section_rewrites_it(self):
        self.write_pin(NEWEST_VERSION, antigravity=expected_antigravity("1.3.0"))
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["antigravity"], expected_antigravity())

    def test_new_acp_version_in_the_bundle_reaches_the_pin(self):
        tarball = cli_tarball(acp_table(version="1.5.0"))
        body = release_list(
            release(NEWEST, digests={f"t3-{NEWEST_VERSION}-linux-x64.tar.gz": f"sha256:{sha256_hex(tarball)}"})
        )
        self.write_pin("0.0.45-nightly.20261001.1000")
        result = self.run_release(body=body, tarball=tarball, extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(self.output.read_text())["antigravity"], expected_antigravity("1.5.0")
        )

    def test_unreadable_table_exits_2_and_keeps_the_pin_byte_identical(self):
        cases = {
            "renamed variable": (cli_tarball(acp_table(variable="assets")), "no Antigravity release table"),
            "missing system": (cli_tarball(acp_table(keys=("darwin-arm64", "linux-x64"))), "linux-arm64"),
            "foreign host": (cli_tarball(acp_table(url_prefix="https://example.invalid/")), "outside"),
        }
        for name, (tarball, needle) in cases.items():
            with self.subTest(case=name):
                self.write_pin("0.0.45-nightly.20261001.1000")
                before = self.output.read_bytes()
                digest = f"sha256:{sha256_hex(tarball)}"
                body = release_list(
                    release(NEWEST, digests={f"t3-{NEWEST_VERSION}-linux-x64.tar.gz": digest})
                )
                result = self.run_release(body=body, tarball=tarball, extra_args=["-o", str(self.output)])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(needle, result.stderr)
                self.assertEqual(self.output.read_bytes(), before)

    def test_tarball_digest_mismatch_exits_2_and_keeps_the_pin_byte_identical(self):
        self.write_pin("0.0.45-nightly.20261001.1000")
        before = self.output.read_bytes()
        result = self.run_release(
            tarball=cli_tarball(acp_table(version="9.9.9")), extra_args=["-o", str(self.output)]
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("expected", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_same_version_higher_build_is_newer(self):
        self.write_pin("0.0.46-nightly.20261004.2643")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], NEWEST_VERSION)

    def test_lower_date_is_older_even_with_a_higher_build(self):
        # Pinned build number is higher, but its date is later, so the
        # resolved nightly is older and must not replace it.
        self.write_pin("0.0.46-nightly.20261005.2600")
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_higher_semver_with_an_older_date_is_newer(self):
        self.write_pin("0.0.45-nightly.20261005.9999")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], NEWEST_VERSION)

    def test_selection_compares_dates_not_list_order_or_build_alone(self):
        body = json.dumps(
            [
                release("v0.0.46-nightly.20261003.2900"),
                release(NEWEST),
                release("v0.0.45-nightly.20261009.3000"),
            ]
        )
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], NEWEST)

    def test_ignores_drafts_and_nightly_tags_not_marked_prerelease(self):
        body = json.dumps(
            [
                release("v0.0.47-nightly.20261009.3000", draft=True),
                release("v0.0.47-nightly.20261009.3001", prerelease=False),
                release(NEWEST),
            ]
        )
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tag"], NEWEST)

    def test_refuses_a_list_without_a_nightly(self):
        body = json.dumps(
            [release("v0.0.47", prerelease=False), release("v0.0.47-preview.20261005.2700")]
        )
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assert_refused(result, "no nightly")

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
