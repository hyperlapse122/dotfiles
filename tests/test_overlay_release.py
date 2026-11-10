import copy
import hashlib
import importlib.machinery
import json
from pathlib import Path
import unittest

release = importlib.machinery.SourceFileLoader("overlay_release", str(Path(__file__).resolve().parents[1] / "scripts/overlay-release")).load_module()


class OverlayReleaseTests(unittest.TestCase):
    def setUp(self):
        self.url = "https://github.com/owner/repo/releases/download/v1.0/font-1.0.zip"
        self.new_url = self.url.replace("1.0", "2.0")
        self.pin = {"font": {"tag": "v1.0", "url": self.url, "sha256": "old"}}
        self.data = {"tag_name": "v2.0", "assets": [{"name": "font-2.0.zip", "browser_download_url": self.new_url}]}

    def fetch(self, url):
        return json.dumps(self.data).encode() if url.endswith("/latest") else b"archive"

    def test_font_update(self):
        result = release.refresh(self.pin, self.fetch)
        self.assertEqual(result["font"]["url"], self.new_url)
        self.assertEqual(result["font"]["sha256"], hashlib.sha256(b"archive").hexdigest())

    def test_bun_preserves_target_metadata(self):
        pin = {"tag": "v1.0", "targets": {"linux": dict(self.pin["font"], path="bun", format="zip")}}
        del pin["targets"]["linux"]["tag"]
        self.assertEqual(release.refresh(pin, self.fetch)["targets"]["linux"]["path"], "bun")

    def test_incomplete_or_untrusted_release_leaves_input_unchanged(self):
        for mutate in [
            lambda d: d.update(assets=[]),
            lambda d: d.update(prerelease=True),
            lambda d: d.update(tag_name="nightly"),
            lambda d: d["assets"][0].update(browser_download_url="https://other.invalid/file"),
            lambda d: d["assets"][0].update(digest="sha256:wrong"),
        ]:
            original = copy.deepcopy(self.pin)
            data = copy.deepcopy(self.data)
            mutate(self.data)
            with self.assertRaises(ValueError):
                release.refresh(self.pin, self.fetch)
            self.assertEqual(self.pin, original)
            self.data = data

    def test_no_downgrade(self):
        self.data["tag_name"] = "v0.9"
        self.assertEqual(release.refresh(self.pin, self.fetch), self.pin)


if __name__ == "__main__":
    unittest.main()
