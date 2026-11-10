"""Drive the release CLI through real curl against local Packages fixtures."""

import json
import http.server
import threading
import time
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/chatgpt-release"

NEWEST_HEX = "c463727f1ed5dced78338c8e2a65d889bd153276ff373fd77698ccb9af32d181"
NEWEST_SRI = "sha256-xGNyfx7V3O14M4yOKmXYib0VMnb/Nz/XdpjMua8y0YE="
NEWEST_FILENAME = "pool/main/c/chatgpt/chatgpt_26.928.31416_amd64.deb"


def stanza(version, sha256, package="chatgpt", arch="amd64", filename=None):
    if filename is None:
        filename = f"pool/main/c/{package}/{package}_{version}_{arch}.deb"
    return (
        f"Package: {package}\n"
        f"Version: {version}\n"
        f"Architecture: {arch}\n"
        f"Filename: {filename}\n"
        f"SHA256: {sha256}\n"
        "Description: fixture\n"
        " continuation line: not a field\n"
    )


SAMPLE_PACKAGES = "\n".join(
    [
        stanza("1.0.0", "0" * 64, package="irrelevant-package"),
        stanza("26.928.9", "1" * 64),
        stanza("26.928.31416", NEWEST_HEX),
    ]
)

class ChatgptReleaseTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.source = root / "Packages"
        self.output = root / "chatgpt-version.json"

    def run_release(self, body=SAMPLE_PACKAGES, extra_args=None, source_url=None):
        self.source.write_text(body)
        args = [sys.executable, str(SCRIPT), "--source-url", source_url or self.source.as_uri()]
        args.extend(extra_args if extra_args else ["--dry-run"])
        return subprocess.run(args, capture_output=True, text=True, timeout=75)

    def serve(self, handler):
        server = http.server.HTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()
        def cleanup():
            server.server_close()
            thread.join(timeout=2)
        self.addCleanup(cleanup)
        return f"http://127.0.0.1:{server.server_port}/Packages"

    def write_pin(self, version, **overrides):
        self.output.write_text(
            json.dumps(
                {
                    "version": version,
                    "filename": f"pool/main/c/chatgpt/chatgpt_{version}_amd64.deb",
                    "sha256": NEWEST_HEX,
                    "hash": NEWEST_SRI,
                    **overrides,
                },
                indent=2,
            )
            + "\n"
        )

    def test_picks_the_highest_version_with_its_pool_filename(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "version": "26.928.31416",
                "filename": NEWEST_FILENAME,
                "sha256": NEWEST_HEX,
                "hash": NEWEST_SRI,
            },
        )

    def test_numeric_version_comparison_beats_lexical(self):
        body = "\n".join([stanza("26.10.0", "2" * 64), stanza("26.9.0", "1" * 64)])
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "26.10.0")

    def test_ignores_non_amd64_architectures(self):
        body = "\n".join(
            [stanza("27.0.0", "1" * 64, arch="arm64"), stanza("26.928.31416", NEWEST_HEX)]
        )
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["version"], "26.928.31416")

    def test_writes_a_newer_version_to_the_pin(self):
        self.write_pin("26.928.9")
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("updated", result.stdout)
        data = json.loads(self.output.read_text())
        self.assertEqual(data["version"], "26.928.31416")
        self.assertEqual(data["filename"], NEWEST_FILENAME)
        self.assertEqual(data["hash"], NEWEST_SRI)

    def test_writes_a_pin_when_none_exists(self):
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "26.928.31416")

    def test_same_version_leaves_the_pin_byte_identical(self):
        self.write_pin("26.928.31416")
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already up to date", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_refuses_a_downgrade(self):
        self.write_pin("26.1001.1")
        before = self.output.read_bytes()
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not newer", result.stdout)
        self.assertEqual(self.output.read_bytes(), before)

    def test_unreadable_existing_pin_is_treated_as_absent(self):
        self.output.write_text(json.dumps([1, 2, 3]))
        result = self.run_release(extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())["version"], "26.928.31416")

    def test_no_matching_package_fails(self):
        body = stanza("1.0.0", "0" * 64, package="some-other-pkg")
        result = self.run_release(body=body, extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid chatgpt packages found", result.stderr)
        self.assertFalse(self.output.exists())

    def test_stanza_without_filename_is_skipped(self):
        body = stanza("26.928.31416", NEWEST_HEX, filename="")
        result = self.run_release(body=body)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid chatgpt packages found", result.stderr)

    def test_fetch_error_fails(self):
        self.write_pin("26.928.9")
        before = self.output.read_bytes()
        result = self.run_release(
            source_url=self.source.with_name("missing").as_uri(),
            extra_args=["-o", str(self.output)],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("fetching", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_same_version_identity_drift_fails_without_rewriting(self):
        for field, value in [("filename", "pool/changed.deb"), ("sha256", "2" * 64),
                             ("hash", "sha256-changed")]:
            with self.subTest(field=field):
                self.write_pin("26.928.31416", **{field: value})
                before = self.output.read_bytes()
                result = self.run_release(extra_args=["-o", str(self.output)])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("identity changed", result.stderr)
                self.assertEqual(self.output.read_bytes(), before)

    def test_http_error_with_valid_package_body_preserves_pin(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(503)
                self.end_headers()
                self.wfile.write(SAMPLE_PACKAGES.encode())

            def log_message(self, *args):
                pass

        self.write_pin("26.928.9")
        before = self.output.read_bytes()
        result = self.run_release(source_url=self.serve(Handler),
                                  extra_args=["-o", str(self.output)])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("fetching", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)

    def test_stalled_response_is_bounded_and_preserves_pin(self):
        release = threading.Event()
        entered = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                entered.set()
                release.wait(90)

            def log_message(self, *args):
                pass

        url = self.serve(Handler)
        self.addCleanup(release.set)
        self.write_pin("26.928.9")
        before = self.output.read_bytes()
        started = time.monotonic()
        result = self.run_release(source_url=url, extra_args=["-o", str(self.output)])
        self.assertTrue(entered.is_set(), "fixture never accepted the request")
        self.assertLess(time.monotonic() - started, 75)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed with status 28", result.stderr)
        self.assertEqual(self.output.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
