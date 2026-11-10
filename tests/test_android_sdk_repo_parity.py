"""Drive android-sdk-repo-parity.py against small pin and nixpkgs repo.json files.

A system image is keyed api -> tag -> abi in both files, with no revision in
the key, so a pin that tracks a newer image revision than nixpkgs lists meets
nixpkgs' older record under the same key. That is the case the check must
skip rather than report as drift.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The flake check copies each file to the store on its own, so it names the
# script through ANDROID_SDK_REPO_PARITY; run directly, the sibling is used.
SCRIPT = os.environ.get("ANDROID_SDK_REPO_PARITY") or Path(__file__).resolve().parent / "android-sdk-repo-parity.py"


def image(revision, abi_key="abi:5", extra_tag=False):
    entry = {
        "archives": [
            {
                "arch": "all",
                "os": "all",
                "sha1": f"sha-{revision}",
                "size": revision,
                "url": f"https://dl.google.com/x86_64-37.0_r{revision:02d}.zip",
            }
        ],
        "revision-details": {"major:0": str(revision)},
        "type-details": {abi_key: "x86_64", "api-level:0": "37.0"},
    }
    if extra_tag:
        entry["type-details"]["tag:4"] = {"id:0": "ai_glasses_compatible"}
    return entry


def platform(revision="1"):
    return {
        "archives": [{"sha1": "platform", "url": "https://dl.google.com/platform-37.zip"}],
        "revision-details": {"major:0": revision},
    }


def repo(image_entry, platform_entry=None):
    return {
        "packages": {"platforms": {"37.0": platform_entry or platform()}},
        "images": {"37.0": {"google_apis": {"x86_64": image_entry}}},
    }


class ParityTests(unittest.TestCase):
    def run_parity(self, pin, upstream):
        with tempfile.TemporaryDirectory() as tmp:
            pin_path = Path(tmp) / "pin.json"
            upstream_path = Path(tmp) / "upstream.json"
            pin_path.write_text(json.dumps(pin))
            upstream_path.write_text(json.dumps(upstream))
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(pin_path), str(upstream_path)],
                capture_output=True,
                text=True,
            )

    def test_identical_entries_pass(self):
        result = self.run_parity(repo(image(6)), repo(image(6)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("system-image 37.0 google_apis x86_64", result.stdout)

    def test_same_revision_that_differs_fails(self):
        result = self.run_parity(repo(image(6)), repo(image(6, abi_key="abi:6", extra_tag=True)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system-image 37.0 google_apis x86_64 differs in type-details", result.stderr)

    def test_newer_pinned_image_revision_is_skipped(self):
        result = self.run_parity(repo(image(8)), repo(image(6, abi_key="abi:6", extra_tag=True)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip system-image 37.0 google_apis x86_64: revision 8 not in nixpkgs repo.json (it has 6)", result.stdout)
        self.assertIn("matches nixpkgs repo.json: platforms 37.0", result.stdout)

    def test_older_pinned_image_revision_fails(self):
        result = self.run_parity(repo(image(6)), repo(image(8)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system-image 37.0 google_apis x86_64 revision 6 is older than nixpkgs' 8", result.stderr)

    def test_revision_compares_numerically(self):
        result = self.run_parity(repo(image(10)), repo(image(9)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("revision 10 not in nixpkgs repo.json (it has 9)", result.stdout)

    def test_revision_with_another_field_set_is_compared_not_skipped(self):
        pin_image = image(6)
        pin_image["revision-details"]["micro:2"] = "0"
        pin_image["archives"][0]["sha1"] = "drifted"
        result = self.run_parity(repo(pin_image), repo(image(6)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system-image 37.0 google_apis x86_64 differs in archives, revision-details", result.stderr)

    def test_missing_revision_details_is_compared_not_skipped(self):
        upstream_image = image(6)
        del upstream_image["revision-details"]
        result = self.run_parity(repo(image(8)), repo(upstream_image))
        self.assertEqual(result.returncode, 1)
        self.assertIn("system-image 37.0 google_apis x86_64 differs in archives, revision-details", result.stderr)

    def test_non_numeric_revision_is_compared_not_a_crash(self):
        pin_image = image(6)
        pin_image["revision-details"]["major:0"] = "6-rc1"
        result = self.run_parity(repo(pin_image), repo(image(6)))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("system-image 37.0 google_apis x86_64 differs in revision-details", result.stderr)

    def test_multi_field_revision_orders_by_each_field(self):
        pin_image, upstream_image = image(37), image(37)
        pin_image["revision-details"].update({"minor:1": "2", "micro:2": "12"})
        upstream_image["revision-details"].update({"minor:1": "2", "micro:2": "11"})
        result = self.run_parity(repo(pin_image), repo(upstream_image))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("revision 37.2.12 not in nixpkgs repo.json (it has 37.2.11)", result.stdout)
        result = self.run_parity(repo(upstream_image), repo(pin_image))
        self.assertEqual(result.returncode, 1)
        self.assertIn("revision 37.2.11 is older than nixpkgs' 37.2.12", result.stderr)

    def test_newer_pinned_package_revision_is_skipped(self):
        pin = repo(image(6), platform("2"))
        pin["packages"]["build-tools"] = {"37.0.0": platform()}
        upstream = repo(image(6), platform("1"))
        upstream["packages"]["build-tools"] = {"37.0.0": platform()}
        result = self.run_parity(pin, upstream)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip platforms 37.0: revision 2 not in nixpkgs repo.json (it has 1)", result.stdout)

    def test_entry_nixpkgs_does_not_list_is_skipped(self):
        pin = repo(image(6))
        pin["packages"]["emulator"] = {"37.2.12": platform()}
        result = self.run_parity(pin, repo(image(6)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip emulator 37.2.12: not in nixpkgs repo.json", result.stdout)
        self.assertNotIn("emulator", result.stdout.splitlines()[-1])

    def test_only_skipped_entries_assert_nothing(self):
        pin = repo(image(8))
        del pin["packages"]
        result = self.run_parity(pin, repo(image(6)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no pinned package is in nixpkgs repo.json to compare", result.stderr)


if __name__ == "__main__":
    unittest.main()
