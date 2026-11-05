import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
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


class ClaudePersonalAppLockTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="claude lock ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data_dir = self.root / "home/.chezmoidata"
        self.data_dir.mkdir(parents=True)
        self.application = {
            "command": "claude", "source": "claude", "repository": "anthropics/claude-code",
            "targets": {
                "linux-amd64": {"platform": "linux-x64", "asset": "claude", "kind": "file"},
                "windows-arm64": {"platform": "win32-arm64", "asset": "claude.exe", "kind": "file"},
            },
        }
        self.declaration = self.data_dir / "personal-apps.json"
        self.declaration.write_text(json.dumps({"personalApps": {"claude": self.application}}), encoding="utf-8")
        self.lock = self.data_dir / "personal-app-lock.json"
        self.lock.write_text('{"previous": true}\n', encoding="utf-8")
        self.previous = self.lock.read_bytes()
        self.version = "2.1.318"
        self.manifest = {"version": self.version, "platforms": {
            "linux-x64": {"binary": "claude", "checksum": "a" * 64, "size": 100},
            "win32-arm64": {"binary": "claude.exe", "checksum": "b" * 64, "size": 200},
        }}

    def refresh(self):
        return UPDATER.update_lock(
            self.root, lambda _: self.fail("Claude must not use GitHub releases"),
            fetch_claude_release=lambda: (self.version, self.manifest),
        )

    def test_native_manifest_resolves_and_reapply_is_unchanged(self):
        self.assertTrue(self.refresh())
        pin = json.loads(self.lock.read_text(encoding="utf-8"))["personalAppLocks"]["claude"]
        self.assertEqual(pin, {"tag": "2.1.318", "targets": {
            "linux-amd64": {"kind": "file", "sha256": "a" * 64,
                "url": "https://downloads.claude.ai/claude-code-releases/2.1.318/linux-x64/claude"},
            "windows-arm64": {"kind": "file", "sha256": "b" * 64,
                "url": "https://downloads.claude.ai/claude-code-releases/2.1.318/win32-arm64/claude.exe"},
        }})
        stamp = self.lock.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual(self.lock.stat().st_mtime_ns, stamp)

    def test_invalid_or_incomplete_manifest_preserves_previous_lock(self):
        original = copy.deepcopy(self.manifest)
        invalid = []
        for field, value in (("binary", "../claude"), ("checksum", "bad")):
            manifest = copy.deepcopy(original)
            manifest["platforms"]["linux-x64"][field] = value
            invalid.append(manifest)
        missing = copy.deepcopy(original)
        del missing["platforms"]["win32-arm64"]
        invalid.extend([missing, {**original, "version": "2.1.0"}])
        for manifest in invalid:
            with self.subTest(manifest=manifest):
                self.manifest = manifest
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)
        self.manifest = original
        self.version = "../latest"
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)


class GitLabPersonalAppLockTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="gitlab personal app lock ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data_dir = self.root / "home/.chezmoidata"
        self.data_dir.mkdir(parents=True)
        self.application = {
            "command": "glab", "source": "gitlab", "repository": "gitlab-org/cli",
            "targets": {
                target: {
                    "asset": "glab_{version}_" + target.replace("-", "_") + (
                        ".zip" if target.startswith("windows-") else ".tar.gz"
                    ),
                    "kind": "archive-file",
                    "format": "zip" if target.startswith("windows-") else "tar.gz",
                    "path": "bin/glab.exe" if target.startswith("windows-") else "bin/glab",
                } for target in (
                    "darwin-arm64", "linux-amd64", "linux-arm64", "windows-amd64", "windows-arm64",
                )
            },
        }
        self.digests = {
            "darwin-arm64": "541cdde6a0f706b4b69fed9fb558b421a361f63408d072d78ffdf304aee04248",
            "linux-amd64": "bc024819e7598b19429a199cd87f640d98b2b67416d8ad796f19e4260b57a7c7",
            "linux-arm64": "60d0512085a8c1be7c5ef51aa7e4ee28213444cea0376b3260707d90489199ea",
            "windows-amd64": "641d86af5d72c17a7d79154a6436e9c68a54c69db2172020cc4036e0776a4832",
            "windows-arm64": "a2e8a2ac9dc918a6ce1334c2a784accd581d9845329abf6aea72fe1ca1f1a13c",
        }
        self.base_url = "https://gitlab.com/gitlab-org/cli/-/releases/v1.128.0/downloads/"
        names = [
            declaration["asset"].replace("{version}", "1.128.0")
            for declaration in self.application["targets"].values()
        ]
        self.checksums = "".join(
            digest.upper() + "  " + name + "\n"
            for digest, name in zip(self.digests.values(), names)
        )
        self.release = {
            "tag_name": "v1.128.0", "upcoming_release": False,
            "assets": {"links": [{
                "name": name,
                "direct_asset_url": self.base_url + name,
                "url": (
                    "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/"
                    "glab/1%2E128%2E0/" + name.replace(".", "%2E")
                ),
            } for name in names + ["checksums.txt"]]},
        }
        self.manifest = self.data_dir / "personal-apps.json"
        self.manifest.write_text(json.dumps({"personalApps": {"glab": self.application}}), encoding="utf-8")
        self.lock_path = self.data_dir / "personal-app-lock.json"
        self.lock_path.write_text('{"keep": "previous pins"}\n', encoding="utf-8")
        self.previous = self.lock_path.read_bytes()

    def refresh(self, release=None, checksums=None):
        def fetch_release(repository):
            self.assertEqual(repository, "gitlab-org/cli")
            return self.release if release is None else release

        def fetch_checksums(url):
            self.assertEqual(url, self.base_url + "checksums.txt")
            return self.checksums if checksums is None else checksums

        return UPDATER.update_lock(
            self.root, lambda repository: self.fail("GitLab must not use the GitHub fetcher"),
            fetch_gitlab_release=fetch_release, fetch_checksums=fetch_checksums,
        )

    def test_official_release_normalizes_to_existing_lock_schema(self):
        self.assertTrue(self.refresh())
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))["personalAppLocks"]["glab"]
        self.assertEqual(lock, {"tag": "v1.128.0", "targets": {
            target: {
                "kind": "archive-file", "format": declaration["format"], "path": declaration["path"],
                "sha256": self.digests[target],
                "url": self.base_url + declaration["asset"].replace("{version}", "1.128.0"),
            } for target, declaration in self.application["targets"].items()
        }})
        before = self.lock_path.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual(self.lock_path.stat().st_mtime_ns, before)

    def test_mixed_sources_preserve_github_fetcher_and_atomic_publication(self):
        github = {
            "command": "example", "source": "github", "repository": "owner/example",
            "targets": {"linux-amd64": {"asset": "example", "kind": "file"}},
        }
        github_release = {"tag_name": "v2.0.0", "assets": [{
            "name": "example", "state": "uploaded", "digest": "sha256:" + "a" * 64,
            "browser_download_url": "https://github.com/owner/example/releases/download/v2.0.0/example",
        }]}
        self.manifest.write_text(json.dumps({"personalApps": {
            "example": github, "glab": self.application,
        }}), encoding="utf-8")

        def fetch_github(repository):
            self.assertEqual(repository, "owner/example")
            return github_release

        def refresh():
            return UPDATER.update_lock(
                self.root, fetch_github, fetch_gitlab_release=lambda repository: self.release,
                fetch_checksums=lambda url: self.checksums,
            )

        self.assertTrue(refresh())
        published = self.lock_path.read_bytes()
        lock = json.loads(published)["personalAppLocks"]
        self.assertEqual(lock["example"]["targets"]["linux-amd64"]["sha256"], "a" * 64)
        self.assertEqual(lock["glab"]["tag"], "v1.128.0")
        github_release["assets"][0]["digest"] = "sha256:" + "b" * 64
        self.release["assets"]["links"].pop()
        with self.assertRaises(ValueError):
            refresh()
        self.assertEqual(self.lock_path.read_bytes(), published)

    def test_missing_duplicate_and_untrusted_assets_preserve_lock(self):
        cases = []
        for index in (0, -1):
            missing = copy.deepcopy(self.release)
            missing["assets"]["links"].pop(index)
            cases.append(missing)
            duplicate = copy.deepcopy(self.release)
            duplicate["assets"]["links"].append(copy.deepcopy(duplicate["assets"]["links"][index]))
            cases.append(duplicate)
            for field in ("url", "direct_asset_url"):
                for replacement in (
                    "http://gitlab.com/untrusted", "https://gitlab.com.evil.invalid/untrusted",
                    "https://evil.invalid/untrusted", self.base_url + "different-asset",
                    self.base_url.replace("v1.128.0", "v1.127.0") + "checksums.txt",
                    self.base_url + "checksums.txt?redirect=1",
                ):
                    wrong_url = copy.deepcopy(self.release)
                    wrong_url["assets"]["links"][index][field] = replacement
                    cases.append(wrong_url)
        for release in cases:
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    self.refresh(release=release)
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_missing_duplicate_or_malformed_checksums_preserve_lock(self):
        first_line = self.checksums.splitlines()[0]
        for checksums in (
            "", "\n".join(self.checksums.splitlines()[1:]),
            self.checksums + first_line + "\n",
            self.checksums.replace(first_line[:64], "abc"),
            self.checksums.replace(first_line[:64], "g" * 64),
            self.checksums + "not a checksum\n",
        ):
            with self.subTest(checksums=checksums):
                with self.assertRaises(ValueError):
                    self.refresh(checksums=checksums)
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_unpublished_and_prerelease_tags_are_rejected(self):
        cases = [
            {**self.release, "upcoming_release": True},
            *({**self.release, "tag_name": tag} for tag in ("", "v1.128.0-rc1", "../v1.128.0")),
        ]
        for release in cases:
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    self.refresh(release=release)
                self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_checksum_fetch_failure_preserves_lock(self):
        def fail(url):
            raise OSError("checksum download failed")

        with self.assertRaises(OSError):
            UPDATER.update_lock(
                self.root, fetch_gitlab_release=lambda repository: self.release, fetch_checksums=fail,
            )
        self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_unknown_source_is_rejected_before_network_access(self):
        self.application["source"] = "untrusted"
        self.manifest.write_text(json.dumps({"personalApps": {"glab": self.application}}), encoding="utf-8")
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(self.lock_path.read_bytes(), self.previous)

    def test_gitlab_latest_api_uses_public_official_host(self):
        with patch.object(UPDATER, "urlopen") as request:
            request.return_value.__enter__.return_value.read.return_value = json.dumps(self.release).encode()
            self.assertEqual(UPDATER.gitlab_release("gitlab-org/cli"), self.release)
            self.assertEqual(
                request.call_args.args[0],
                "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest",
            )



if __name__ == "__main__":
    unittest.main()
