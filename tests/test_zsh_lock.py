import base64
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("zsh_lock", REPO / "scripts/update-zsh-lock.py")
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class ZshLockTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="zsh lock ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.data = self.root / "home/.chezmoidata"
        self.data.mkdir(parents=True)
        self.manifest = {"repository": "owner/prezto", "ref": "master", "submodules": ["modules/completion/external"]}
        (self.data / "zsh.json").write_text(json.dumps({"zsh": self.manifest}), encoding="utf-8")
        self.lock = self.data / "zsh-lock.json"
        self.lock.write_bytes(b'{"previous": true}\n')
        self.previous = self.lock.read_bytes()
        self.responses = {
            "repos/owner/prezto/commits/master": {"sha": "a" * 40},
            "repos/owner/prezto/git/trees/" + "a" * 40 + "?recursive=1": {
                "tree": [{"path": "modules/completion/external", "mode": "160000", "sha": "b" * 40}]},
            "repos/owner/prezto/contents/.gitmodules?ref=" + "a" * 40: self.modules("modules/completion/external", "owner/completions"),
            "repos/owner/completions/git/trees/" + "b" * 40 + "?recursive=1": {
                "tree": [{"path": "nested", "mode": "160000", "sha": "c" * 40}]},
            "repos/owner/completions/contents/.gitmodules?ref=" + "b" * 40: self.modules("nested", "owner/nested"),
            "repos/owner/nested/git/trees/" + "c" * 40 + "?recursive=1": {"tree": []},
        }

    @staticmethod
    def modules(path, repository):
        body = f'[submodule "{path}"]\npath = {path}\nurl = https://github.com/{repository}.git\n'
        return {"content": base64.b64encode(body.encode()).decode()}

    def refresh(self, fetch=None, download=None):
        return UPDATER.update_lock(self.root, fetch or self.responses.__getitem__, download or (lambda url: url.encode()))

    def test_recursive_gitlinks_follow_parent_commits_and_unchanged_lock_is_not_rewritten(self):
        self.assertTrue(self.refresh())
        archives = json.loads(self.lock.read_text(encoding="utf-8"))["zshLock"]["archives"]
        self.assertEqual([item["path"] for item in archives], ["", "modules/completion/external", "modules/completion/external/nested"])
        self.assertEqual([item["commit"] for item in archives], ["a" * 40, "b" * 40, "c" * 40])
        for item in archives:
            self.assertIn(item["commit"], item["url"])
            self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")
        os.utime(self.lock, ns=(1000000000, 1000000000))
        before = self.lock.read_bytes(), self.lock.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual((self.lock.read_bytes(), self.lock.stat().st_mtime_ns), before)

    def test_missing_selected_gitlink_preserves_previous_lock(self):
        self.responses["repos/owner/prezto/git/trees/" + "a" * 40 + "?recursive=1"] = {"tree": []}
        with self.assertRaisesRegex(ValueError, "completion/external"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_invalid_commit_or_archive_failure_preserves_previous_lock(self):
        self.responses["repos/owner/prezto/commits/master"] = {"sha": "short"}
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)
        self.responses["repos/owner/prezto/commits/master"] = {"sha": "a" * 40}

        def fail_nested(url):
            if "nested/" in url:
                raise OSError("archive unavailable")
            return b"archive"

        with self.assertRaises(OSError):
            self.refresh(download=fail_nested)
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_gitmodules_cannot_publish_outside_staging(self):
        tree = self.responses["repos/owner/completions/git/trees/" + "b" * 40 + "?recursive=1"]
        tree["tree"][0]["path"] = "../escape"
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)


@unittest.skipUnless(shutil.which("chezmoi"), "Real chezmoi executable required")
class ZshExternalTest(unittest.TestCase):
    def render(self, os_name, arch="amd64", mutate=None):
        template = (REPO / "home/.chezmoitemplates/external-assets/zsh.toml.tmpl").read_text(encoding="utf-8")
        data = {}
        for name in ("zsh.json", "zsh-lock.json"):
            data.update(json.loads((REPO / "home/.chezmoidata" / name).read_text(encoding="utf-8")))
        data["chezmoi"] = {"os": os_name, "arch": arch}
        if mutate:
            mutate(data)
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            config = root / "chezmoi.toml"
            config.write_text("", encoding="utf-8")
            wrapper = "{{- $data := " + json.dumps(json.dumps(data)) + " | fromJson -}}{{- with $data -}}" + template + "{{- end -}}"
            return subprocess.run(["chezmoi", "--config", str(config), "--source", str(root), "execute-template"],
                                  input=wrapper, capture_output=True, text=True, encoding="utf-8", timeout=30)

    def test_eligible_targets_share_complete_immutable_archives_and_windows_is_empty(self):
        pins = json.loads((REPO / "home/.chezmoidata/zsh-lock.json").read_text(encoding="utf-8"))["zshLock"]["archives"]
        expected = None
        for os_name, arch in (("linux", "amd64"), ("linux", "arm64"), ("darwin", "arm64")):
            result = self.render(os_name, arch)
            self.assertEqual(result.returncode, 0, result.stderr)
            entries = tomllib.loads(result.stdout)
            self.assertEqual(len(entries), len(pins))
            for pin in pins:
                path = ".local/share/dotfiles/zsh/prezto" + ("/" + pin["path"] if pin["path"] else "")
                self.assertEqual(entries[path]["checksum"]["sha256"], pin["sha256"])
                self.assertIn(pin["commit"], entries[path]["url"])
            if expected is None:
                expected = entries
            self.assertEqual(entries, expected)
        self.assertEqual(self.render("windows").stdout.strip(), "")
        self.assertEqual(self.render("darwin", "amd64").stdout.strip(), "")

    def test_incomplete_pin_fails_before_acquisition(self):
        for key in ("commit", "sha256"):
            result = self.render("linux", mutate=lambda data: data["zshLock"]["archives"][0].pop(key))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pin", result.stderr.lower())
        result = self.render("linux", mutate=lambda data: data["zshLock"]["archives"].pop())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required", result.stderr)


if __name__ == "__main__":
    unittest.main()
