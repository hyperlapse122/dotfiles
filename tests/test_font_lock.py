import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("font_lock", REPO / "scripts/update-font-lock.py")
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class FontLockTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="font lock ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.data = self.root / "home/.chezmoidata"
        self.data.mkdir(parents=True)
        self.declaration = {
            "repository": "owner/fonts", "assetPattern": r"Fonts-{version}\.zip",
            "format": "zip", "selections": [
                {"pattern": "static/*.ttf", "minimum": 2},
                {"pattern": "variable/*.ttf", "minimum": 1},
            ],
        }
        self.entries = [("static/Regular.ttf", b"regular"), ("static/Bold.ttf", b"bold"),
                        ("variable/Variable.ttf", b"variable"), ("web/Regular.woff2", b"web"),
                        ("static/Regular.otf", b"duplicate-format")]
        self.payload = self.archive()
        self.release = {
            "tag_name": "v1.2.3", "draft": False, "prerelease": False,
            "assets": [{"name": "Fonts-1.2.3.zip", "state": "uploaded", "digest": None,
                        "browser_download_url": "https://github.com/owner/fonts/releases/download/v1.2.3/Fonts-1.2.3.zip"}],
        }
        self.lock_path = self.data / "font-lock.json"
        self.lock_path.write_text('{"previous": true}\n', encoding="utf-8")
        self.previous = self.lock_path.read_bytes()

    def archive(self, entries=None, format="zip"):
        stream = io.BytesIO()
        if format == "zip":
            with zipfile.ZipFile(stream, "w") as archive:
                for name, content in self.entries if entries is None else entries:
                    archive.writestr(name, content)
        else:
            with tarfile.open(fileobj=stream, mode="w:xz") as archive:
                for name, content in self.entries if entries is None else entries:
                    info = tarfile.TarInfo(name)
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))
        return stream.getvalue()

    def refresh(self, declarations=None):
        (self.data / "fonts.json").write_text(
            json.dumps({"fonts": declarations or {"example": self.declaration}}), encoding="utf-8")
        return UPDATER.update_lock(self.root, lambda repository: self.release, lambda url: self.payload)

    def test_missing_digest_computes_archive_and_member_hashes_without_rewrite(self):
        self.assertTrue(self.refresh())
        pin = json.loads(self.lock_path.read_text(encoding="utf-8"))["fontLocks"]["example"]
        self.assertEqual(pin["sha256"], hashlib.sha256(self.payload).hexdigest())
        self.assertEqual(pin["tag"], "v1.2.3")
        self.assertEqual(pin["repository"], "owner/fonts")
        self.assertEqual(pin["url"], self.release["assets"][0]["browser_download_url"])
        self.assertEqual(pin["files"], [
            {"path": path, "name": Path(path).name, "sha256": hashlib.sha256(content).hexdigest()}
            for path, content in sorted(self.entries[:3])
        ])
        timestamp = self.lock_path.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual(self.lock_path.stat().st_mtime_ns, timestamp)

    def test_supplied_digest_is_verified(self):
        self.release["assets"][0]["digest"] = "sha256:" + hashlib.sha256(self.payload).hexdigest()
        self.assertTrue(self.refresh())
        self.release["assets"][0]["digest"] = "sha256:" + "0" * 64
        before = self.lock_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.refresh()
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_tar_xz_selects_each_nerd_width_form(self):
        self.declaration.update(assetPattern=r"Nerd\.tar\.xz", format="tar.xz", selections=[
            {"pattern": "*NerdFont-*.ttf", "minimum": 1},
            {"pattern": "*NerdFontMono-*.ttf", "minimum": 1},
            {"pattern": "*NerdFontPropo-*.ttf", "minimum": 1},
        ])
        self.release["assets"][0].update(name="Nerd.tar.xz", browser_download_url=
            "https://github.com/owner/fonts/releases/download/v1.2.3/Nerd.tar.xz")
        self.entries = [(f"Example{form}-Regular.ttf", form.encode()) for form in (
            "NerdFont", "NerdFontMono", "NerdFontPropo")]
        self.payload = self.archive(format="tar.xz")
        self.assertTrue(self.refresh())
        self.entries.pop()
        self.payload = self.archive(format="tar.xz")
        before = self.lock_path.read_bytes()
        with self.assertRaisesRegex(ValueError, "selection"):
            self.refresh()
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_rejects_unstable_release_ambiguous_asset_and_unexpected_url(self):
        original = copy.deepcopy(self.release)
        cases = [dict(draft=True), dict(prerelease=True), dict(tag_name=""),
                 dict(assets=[original["assets"][0], original["assets"][0]])]
        for changes in cases:
            self.release = {**original, **changes}
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.refresh()
            self.assertEqual(self.lock_path.read_bytes(), self.previous)
        self.release = copy.deepcopy(original)
        self.release["assets"][0]["browser_download_url"] = "https://example.org/fonts.zip"
        with self.assertRaisesRegex(ValueError, "URL"):
            self.refresh()
        self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_rejects_unsafe_selected_paths_and_duplicate_destinations(self):
        for extra in ("static/../Escape.ttf", "static/nested/Regular.ttf", "static/regular.ttf"):
            with self.subTest(extra=extra):
                self.payload = self.archive(self.entries + [(extra, b"extra")])
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_rejects_selected_symlink(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for name, content in self.entries:
                archive.writestr(name, content)
            link = zipfile.ZipInfo("static/Link.ttf")
            link.create_system = 3
            link.external_attr = 0o120777 << 16
            archive.writestr(link, "Regular.ttf")
        self.payload = stream.getvalue()
        with self.assertRaisesRegex(ValueError, "regular"):
            self.refresh()
        self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_failed_later_package_preserves_entire_previous_lock(self):
        later = {**self.declaration, "selections": [{"pattern": "missing/*.ttf", "minimum": 1}]}
        with self.assertRaises(ValueError):
            self.refresh({"first": self.declaration, "later": later})
        self.assertEqual(self.lock_path.read_bytes(), self.previous)


if __name__ == "__main__":
    unittest.main()
