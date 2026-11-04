import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("harness_plugin_lock", REPO / "scripts/update-harness-plugin-lock.py")
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class HarnessPluginLockTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="harness plugin lock ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data = self.root / "home/.chezmoidata"
        self.data.mkdir(parents=True)
        self.plugin = {"repository": "owner/plugin", "tagPrefix": "plugin.v", "omp": {"marketplace": "example", "plugin": "example"}}
        self.manifest = self.data / "harness-plugins.json"
        self.manifest.write_text(json.dumps({"harnessPlugins": {"example": self.plugin}}), encoding="utf-8")
        self.lock = self.data / "harness-plugin-lock.json"
        self.lock.write_bytes(b'{"previous": true}\n')
        self.previous = self.lock.read_bytes()
        self.base = "repos/owner/plugin"
        self.release_path = self.base + "/releases/latest"
        self.ref_path = self.base + "/git/ref/tags/plugin.v1.2.3"
        self.responses = {
            self.release_path: {"tag_name": "plugin.v1.2.3", "draft": False, "prerelease": False},
            self.ref_path: {"ref": "refs/tags/plugin.v1.2.3", "object": {"type": "commit", "sha": "a" * 40}},
        }

    def refresh(self):
        return UPDATER.update_lock(self.root, self.responses.__getitem__)

    def pin(self):
        return json.loads(self.lock.read_text(encoding="utf-8"))["harnessPluginLocks"]["example"]

    def test_lightweight_commit_and_semantically_unchanged_lock(self):
        declaration = self.manifest.read_bytes()
        self.assertTrue(self.refresh())
        self.assertEqual(self.pin(), {"tag": "plugin.v1.2.3", "commit": "a" * 40})
        self.lock.write_text(json.dumps({"harnessPluginLocks": {"example": self.pin()}}, indent=4), encoding="utf-8")
        os.utime(self.lock, ns=(1000000000, 1000000000))
        before = self.lock.read_bytes(), self.lock.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual((self.lock.read_bytes(), self.lock.stat().st_mtime_ns), before)
        self.assertEqual(self.manifest.read_bytes(), declaration)

    def test_annotated_and_nested_tags_resolve_terminal_commit(self):
        for depth in (1, 2):
            with self.subTest(depth=depth):
                self.responses[self.ref_path]["object"] = {"type": "tag", "sha": "1" * 40}
                for index in range(1, depth + 1):
                    sha = str(index) * 40
                    target = {"type": "tag", "sha": str(index + 1) * 40} if index < depth else {"type": "commit", "sha": "b" * 40}
                    self.responses[f"{self.base}/git/tags/{sha}"] = {"sha": sha, "object": target}
                self.refresh()
                self.assertEqual(self.pin()["commit"], "b" * 40)

    def test_same_tag_sha_change_updates_pin(self):
        self.refresh()
        self.responses[self.ref_path]["object"]["sha"] = "c" * 40
        self.assertTrue(self.refresh())
        self.assertEqual(self.pin(), {"tag": "plugin.v1.2.3", "commit": "c" * 40})

    def test_wrong_or_incomplete_release_preserves_prior_bytes(self):
        cases = [None, [], {}, {"tag_name": "plugin.v1.2.3"}]
        release = self.responses[self.release_path]
        for key, values in {"tag_name": [None, "other.v1.2.3", "pluginXv1.2.3", "plugin.v1.2.3-rc1", "plugin.v1.2"], "draft": [True, None], "prerelease": [True, None]}.items():
            cases.extend({**release, key: value} for value in values)
        for case in cases:
            with self.subTest(case=case):
                self.responses[self.release_path] = case
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_malformed_refs_and_noncommit_targets_preserve_prior_bytes(self):
        cases = [None, [], {}, {"ref": "refs/tags/wrong", "object": {"type": "commit", "sha": "a" * 40}}]
        for target in (None, {}, {"type": "commit", "sha": "abc"}, {"type": "commit", "sha": None}, {"type": "tree", "sha": "a" * 40}, {"type": "blob", "sha": "a" * 40}):
            cases.append({"ref": "refs/tags/plugin.v1.2.3", "object": target})
        for case in cases:
            with self.subTest(case=case):
                self.responses[self.ref_path] = case
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_incomplete_or_cyclic_annotated_tag_preserves_lock(self):
        self.responses[self.ref_path]["object"] = {"type": "tag", "sha": "1" * 40}
        for case in (None, {}, {"sha": None}, {"sha": "2" * 40, "object": {"type": "commit", "sha": "a" * 40}}, {"sha": "1" * 40}, {"sha": "1" * 40, "object": {"type": "tag", "sha": "1" * 40}}):
            with self.subTest(case=case):
                self.responses[f"{self.base}/git/tags/{'1' * 40}"] = case
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_later_plugin_failure_does_not_publish_partial_result(self):
        second = copy.deepcopy(self.plugin)
        second["repository"] = "owner/second"
        self.manifest.write_text(json.dumps({"harnessPlugins": {"first": self.plugin, "second": second}}), encoding="utf-8")
        self.responses["repos/owner/second/releases/latest"] = {}
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_gh_failure_at_each_boundary_preserves_lock(self):
        self.responses[self.ref_path]["object"] = {"type": "tag", "sha": "1" * 40}
        tag_path = f"{self.base}/git/tags/{'1' * 40}"
        for failure in (self.release_path, self.ref_path, tag_path):
            def fetch(endpoint):
                if endpoint == failure:
                    raise subprocess.CalledProcessError(1, "gh", stderr="lookup failed")
                return self.responses[endpoint]
            with self.subTest(failure=failure):
                with self.assertRaises(subprocess.CalledProcessError):
                    UPDATER.update_lock(self.root, fetch)
                self.assertEqual(self.lock.read_bytes(), self.previous)


if __name__ == "__main__":
    unittest.main()
