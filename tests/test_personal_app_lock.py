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
            "targets": {target: {"asset": f"example-{target}", "kind": "file"} for target in (
                "darwin-arm64", "linux-amd64", "linux-arm64", "windows-amd64", "windows-arm64",
            )},
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
                for i, name in enumerate(target["asset"] for target in self.application["targets"].values())
            ],
        }

    def refresh(self, release=None):
        return UPDATER.update_lock(self.root, lambda repository: self.release if release is None else release)

    def test_complete_release_and_unchanged_reapply(self):
        self.assertTrue(self.refresh())
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["example"]
        self.assertEqual(lock["tag"], "v1.2.3")
        expected = {
            target: {"url": f"https://github.com/owner/example/releases/download/v1.2.3/{declaration['asset']}",
                     "sha256": format(i + 1, "064x"), "kind": "file"}
            for i, (target, declaration) in enumerate(self.application["targets"].items())
        }
        self.assertEqual(lock["targets"], expected)
        before = self.lock_path.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual(self.lock_path.stat().st_mtime_ns, before)

    def test_versioned_archive_asset_and_member_follow_release(self):
        archive = {
            "command": "gh", "repository": "owner/example",
            "targets": {"linux-amd64": {
                "asset": "gh_{version}_linux_amd64.tar.gz", "kind": "archive-file",
                "format": "tar.gz", "path": "gh_{version}_linux_amd64/bin/gh",
            }},
        }
        self.manifest.write_text(json.dumps({"personalApps": {"gh": archive}}), encoding="utf-8")
        for version, tag in (("2.3.4", "v2.3.4"), ("3.4.5", "3.4.5")):
            with self.subTest(tag=tag):
                name = f"gh_{version}_linux_amd64.tar.gz"
                release = {
                    "tag_name": tag, "assets": [{
                        "name": name, "state": "uploaded", "digest": "sha256:" + "a" * 64,
                        "browser_download_url": f"https://github.com/owner/example/releases/download/{tag}/{name}",
                    }],
                }
                self.assertTrue(self.refresh(release))
                lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["gh"]
                self.assertEqual(lock, {"tag": tag, "targets": {"linux-amd64": {
                    "kind": "archive-file", "format": "tar.gz",
                    "path": f"gh_{version}_linux_amd64/bin/gh", "sha256": "a" * 64,
                    "url": f"https://github.com/owner/example/releases/download/{tag}/{name}",
                }}})

    def test_unversioned_zip_archives_retain_platform_member_and_strip_components(self):
        members = {
            "darwin-amd64": "ghq", "darwin-arm64": "ghq",
            "linux-amd64": "ghq", "linux-arm64": "ghq",
            "windows-amd64": "ghq.exe", "windows-arm64": "ghq.exe",
        }
        application = {
            "command": "ghq", "repository": "x-motemen/ghq",
            "targets": {
                target: {
                    "asset": "ghq_" + target.replace("-", "_") + ".zip",
                    "kind": "archive-file", "format": "zip",
                    "path": member, "stripComponents": 1,
                } for target, member in members.items()
            },
        }
        self.manifest.write_text(json.dumps({"personalApps": {"ghq": application}}), encoding="utf-8")
        release = {
            "tag_name": "v1.2.3", "assets": [
                {
                    "name": "ghq_" + target.replace("-", "_") + ".zip",
                    "state": "uploaded", "digest": "sha256:" + "a" * 64,
                    "browser_download_url": (
                        "https://github.com/x-motemen/ghq/releases/download/v1.2.3/"
                        + "ghq_" + target.replace("-", "_") + ".zip"
                    ),
                } for target in members
            ],
        }
        self.assertTrue(self.refresh(release))
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["ghq"]
        self.assertEqual(lock, {"tag": "v1.2.3", "targets": {
            target: {
                "kind": "archive-file", "format": "zip", "path": member,
                "stripComponents": 1, "sha256": "a" * 64,
                "url": (
                    "https://github.com/x-motemen/ghq/releases/download/v1.2.3/"
                    + "ghq_" + target.replace("-", "_") + ".zip"
                ),
            } for target, member in members.items()
        }})

    def test_only_version_placeholder_is_supported(self):
        for pattern in ("example-{tag}", "example-{version!r}", "example-{version:>10}"):
            with self.subTest(pattern=pattern):
                self.application["targets"]["linux-amd64"]["asset"] = pattern
                self.manifest.write_text(json.dumps({"personalApps": {"example": self.application}}), encoding="utf-8")
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_same_tag_digest_change_is_published(self):
        self.refresh()
        self.release["assets"][0]["digest"] = "sha256:" + "f" * 64
        self.assertTrue(self.refresh())
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["example"]
        self.assertEqual(lock["targets"]["darwin-arm64"]["sha256"], "f" * 64)

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
        archive = copy.deepcopy(self.application)
        for target, declaration in archive["targets"].items():
            declaration.update({
                "kind": "archive-file", "format": "zip", "path": f"example_{{version}}/{target}/bin/example",
            })
        self.manifest.write_text(json.dumps({"personalApps": {"first": self.application, "second": archive}}), encoding="utf-8")
        self.refresh()
        complete = self.lock_path.read_bytes()
        cases = [{**self.release, "assets": []}]
        duplicate = copy.deepcopy(self.release)
        duplicate["assets"].append(copy.deepcopy(duplicate["assets"][0]))
        cases.append(duplicate)
        invalid_digest = copy.deepcopy(self.release)
        invalid_digest["assets"][-1]["digest"] = "sha256:invalid"
        cases.append(invalid_digest)
        for release in cases:
            with self.subTest(release=release):
                changed_first = copy.deepcopy(self.release)
                changed_first["assets"][0]["digest"] = "sha256:" + "f" * 64
                releases = iter([changed_first, release])
                with self.assertRaises(ValueError):
                    UPDATER.update_lock(self.root, lambda repository: next(releases))
                self.assertEqual(self.lock_path.read_bytes(), complete)

    def test_query_failure_preserves_lock(self):
        def fail(repository):
            raise subprocess.CalledProcessError(1, "gh")
        with self.assertRaises(subprocess.CalledProcessError):
            UPDATER.update_lock(self.root, fail)
        self.assertEqual(self.lock_path.read_bytes(), self.previous)


if __name__ == "__main__":
    unittest.main()
