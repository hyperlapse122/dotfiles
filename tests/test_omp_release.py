"""Exercise the release updater's published pin and failure boundary offline."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/omp-release"
ORIGIN = "https://build.stencil.so"
BUILD = "20261021-210324-45c35e4"
ASSETS = {
    "x86_64-linux": "omp-linux-x64",
    "aarch64-linux": "omp-linux-arm64",
    "aarch64-darwin": "omp-darwin-arm64",
}


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / "pin.json"
        self.original = b'{"version": "18.12.5", "build": "older"}\n'
        self.output.write_bytes(self.original)
        self.files = []
        for name in ASSETS.values():
            payload = ("native payload " + name).encode()
            (self.root / name).write_bytes(payload)
            self.files.append({
                "name": name,
                "url": f"/d/omp/{BUILD}/{name}",
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
        self.metadata = {"build": {
            "id": BUILD, "product": "omp", "version": "18.12.6",
            "channel": "stable", "commit": "45c35e40c46166dc726ccc52f5d27f40f2449f99",
            "files": self.files,
        }}
        self.fetch = self.root / "curl"
        self.fetch.write_text(
            f"#!{sys.executable}\n"
            "import pathlib, sys\n"
            "name = sys.argv[-1].rsplit('/', 1)[-1]\n"
            "if '?channel=' in name: name = 'metadata.json'\n"
            "sys.stdout.buffer.write((pathlib.Path(__file__).parent / name).read_bytes())\n"
        )
        self.fetch.chmod(0o755)

    def run_updater(self):
        (self.root / "metadata.json").write_text(json.dumps(self.metadata))
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""))
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output)],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def test_verified_build_writes_immutable_pins(self):
        result = self.run_updater()
        self.assertEqual(result.returncode, 0, result.stderr)
        pin = json.loads(self.output.read_text())
        self.assertEqual(pin["version"], "18.12.6")
        self.assertEqual(pin["build"], BUILD)
        self.assertEqual(pin["commit"], self.metadata["build"]["commit"])
        self.assertEqual(set(pin["platforms"]), set(ASSETS))
        for system, name in ASSETS.items():
            digest = hashlib.sha256((self.root / name).read_bytes()).digest()
            self.assertEqual(pin["platforms"][system], {
                "url": f"{ORIGIN}/d/omp/{BUILD}/{name}",
                "hash": "sha256-" + base64.b64encode(digest).decode(),
            })

    def test_failed_lookup_preserves_pin(self):
        self.metadata = {"error": "no_build"}
        result = self.run_updater()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no stable omp build", result.stderr)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_digest_mismatch_preserves_pin(self):
        (self.root / "omp-darwin-arm64").write_bytes(b"corrupted download")
        result = self.run_updater()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest mismatch", result.stderr)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_incomplete_build_preserves_pin(self):
        self.files.pop()
        result = self.run_updater()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no immutable artifact", result.stderr)
        self.assertEqual(self.output.read_bytes(), self.original)

    def test_older_or_identical_release_preserves_pin(self):
        for current in (
            {"version": "18.12.7", "build": "20261022-000000-45c35e4"},
            {"version": "18.12.6", "build": BUILD},
        ):
            with self.subTest(current=current):
                content = json.dumps(current).encode()
                self.output.write_bytes(content)
                result = self.run_updater()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.output.read_bytes(), content)


if __name__ == "__main__":
    unittest.main()
