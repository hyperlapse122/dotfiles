import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("personal_app_lock", REPO / "scripts/update-personal-app-lock.py")
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class PersonalAppLockTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="personal app lock ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data_dir = self.root / "home/.chezmoidata"
        self.data_dir.mkdir(parents=True)
        self.application = {
            "command": "example", "repository": "owner/example",
            "targets": {f"{os}-{arch}": f"example-{os}-{arch}" for os in ("darwin", "linux", "windows") for arch in ("amd64", "arm64")},
        }
        self.manifest = self.data_dir / "personal-apps.json"
        self.manifest.write_text(json.dumps({"personalApps": {"example": self.application}}), encoding="utf-8")
        self.lock_path = self.data_dir / "personal-app-lock.json"
        self.lock_path.write_text('{"keep": "previous pins"}\n', encoding="utf-8")
        self.previous = self.lock_path.read_bytes()
        self.release = {
            "tag_name": "v1.2.3", "draft": False, "prerelease": False,
            "assets": [
                {"name": name, "state": "uploaded", "digest": "sha256:" + format(i + 1, "064x"),
                 "browser_download_url": f"https://github.com/owner/example/releases/download/v1.2.3/{name}"}
                for i, name in enumerate(self.application["targets"].values())
            ],
        }

    def refresh(self, release=None):
        return UPDATER.update_lock(self.root, lambda repository: self.release if release is None else release)

    def test_complete_release_and_unchanged_reapply(self):
        self.assertTrue(self.refresh())
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["example"]
        self.assertEqual(lock["tag"], "v1.2.3")
        expected = {
            target: {"url": f"https://github.com/owner/example/releases/download/v1.2.3/{name}", "sha256": format(i + 1, "064x")}
            for i, (target, name) in enumerate(self.application["targets"].items())
        }
        self.assertEqual(lock["targets"], expected)
        before = self.lock_path.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual(self.lock_path.stat().st_mtime_ns, before)

    def test_same_tag_digest_change_is_published(self):
        self.refresh()
        self.release["assets"][0]["digest"] = "sha256:" + "f" * 64
        self.assertTrue(self.refresh())
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["example"]
        self.assertEqual(lock["targets"]["darwin-amd64"]["sha256"], "f" * 64)

    def test_incomplete_or_ambiguous_release_preserves_lock(self):
        cases = []
        missing = copy.deepcopy(self.release)
        missing["assets"].pop()
        cases.append(missing)
        duplicate = copy.deepcopy(self.release)
        duplicate["assets"].append(copy.deepcopy(duplicate["assets"][0]))
        cases.append(duplicate)
        for digest in (None, "sha256:abc", "sha512:" + "a" * 64):
            malformed = copy.deepcopy(self.release)
            malformed["assets"][-1]["digest"] = digest
            cases.append(malformed)
        wrong_url = copy.deepcopy(self.release)
        wrong_url["assets"][0]["browser_download_url"] = "https://github.com/owner/example/releases/latest/download/example"
        cases.append(wrong_url)
        uploading = copy.deepcopy(self.release)
        uploading["assets"][0]["state"] = "open"
        cases.append(uploading)
        for release in cases:
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    self.refresh(release)
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_later_application_failure_does_not_publish_partial_lock(self):
        self.manifest.write_text(json.dumps({"personalApps": {"first": self.application, "second": self.application}}), encoding="utf-8")
        releases = iter([self.release, {**self.release, "assets": []}])
        with self.assertRaises(ValueError):
            UPDATER.update_lock(self.root, lambda repository: next(releases))
        self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_query_failure_preserves_lock(self):
        def fail(repository):
            raise subprocess.CalledProcessError(1, "gh")
        with self.assertRaises(subprocess.CalledProcessError):
            UPDATER.update_lock(self.root, fail)
        self.assertEqual(self.lock_path.read_bytes(), self.previous)


if __name__ == "__main__":
    unittest.main()
