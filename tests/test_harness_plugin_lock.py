import base64
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
TOOLS = "Read Write Edit Grep Glob AskUserQuestion"


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
        self.skills_manifest = self.data / "harness-skills.json"
        self.skills_manifest.write_text(json.dumps({"harnessSkills": {"writing": {
            "repository": "owner/skills",
            "tagPrefix": "v",
            "frontmatterKeys": ["allowed-tools", "description", "license", "metadata", "name"],
            "skills": {name: {"allowedTools": TOOLS} for name in ("grammar-checker", "humanizer", "style-guide")},
        }}}), encoding="utf-8")
        self.skill_base = "repos/owner/skills"
        self.skill_release_path = self.skill_base + "/releases/latest"
        self.responses[self.skill_release_path] = {"tag_name": "v1.0.0", "draft": False, "prerelease": False}
        self.responses[self.skill_base + "/git/ref/tags/v1.0.0"] = {"ref": "refs/tags/v1.0.0", "object": {"type": "commit", "sha": "d" * 40}}
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS})

    def publish_upstream(self, skills, extra_frontmatter=None, extra_entries=(), truncated=False):
        tree = [{"path": "CLAUDE.md", "mode": "120000", "type": "blob", "sha": "e" * 40},
                {"path": "skills", "mode": "040000", "type": "tree", "sha": "f" * 40}]
        for index, (name, tools) in enumerate(sorted(skills.items())):
            blob = f"{index:040x}"
            tree += [{"path": f"skills/{name}", "mode": "040000", "type": "tree", "sha": "f" * 40},
                     {"path": f"skills/{name}/SKILL.md", "mode": "100644", "type": "blob", "sha": blob},
                     {"path": f"skills/{name}/references", "mode": "040000", "type": "tree", "sha": "f" * 40},
                     {"path": f"skills/{name}/references/rules.md", "mode": "100644", "type": "blob", "sha": "9" * 40}]
            extra = (extra_frontmatter or {}).get(name, "")
            text = (f"---\nname: {name}\ndescription: Example skill\nlicense: MIT\nmetadata:\n  version: \"1.0.0\"\n"
                    f"allowed-tools: {tools}\n{extra}---\n\n# {name}\n")
            self.responses[f"{self.skill_base}/git/blobs/{blob}"] = {"content": base64.encodebytes(text.encode()).decode(), "encoding": "base64"}
        tree += list(extra_entries)
        self.responses[f"{self.skill_base}/git/trees/{'d' * 40}?recursive=1"] = {"sha": "f" * 40, "truncated": truncated, "tree": tree}

    def start_from_reviewed_skill_pin(self):
        reviewed = {"harnessPluginLocks": {"example": {"tag": "plugin.v1.2.2", "commit": "0" * 40}},
                    "harnessSkillLocks": {"writing": {"tag": "v0.9.0", "commit": "c" * 40}}}
        self.lock.write_text(json.dumps(reviewed, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def refresh(self):
        return UPDATER.update_lock(self.root, self.responses.__getitem__)

    def locked(self):
        return json.loads(self.lock.read_text(encoding="utf-8"))

    def pin(self):
        return self.locked()["harnessPluginLocks"]["example"]

    def test_lightweight_commit_and_semantically_unchanged_lock(self):
        declarations = self.manifest.read_bytes(), self.skills_manifest.read_bytes()
        self.assertTrue(self.refresh())
        self.assertEqual(self.pin(), {"tag": "plugin.v1.2.3", "commit": "a" * 40})
        self.assertEqual(self.locked()["harnessSkillLocks"], {"writing": {"tag": "v1.0.0", "commit": "d" * 40}})
        self.lock.write_text(json.dumps(self.locked(), indent=4), encoding="utf-8")
        os.utime(self.lock, ns=(1000000000, 1000000000))
        before = self.lock.read_bytes(), self.lock.stat().st_mtime_ns
        self.assertFalse(self.refresh())
        self.assertEqual((self.lock.read_bytes(), self.lock.stat().st_mtime_ns), before)
        self.assertEqual((self.manifest.read_bytes(), self.skills_manifest.read_bytes()), declarations)

    def test_first_run_appends_skill_pin_after_byte_identical_plugin_pin(self):
        plugin_only = json.dumps({"harnessPluginLocks": {"example": {"tag": "plugin.v1.2.3", "commit": "a" * 40}}}, indent=2, sort_keys=True) + "\n"
        self.lock.write_bytes(plugin_only.encode())
        self.assertTrue(self.refresh())
        self.assertEqual(self.lock.read_text(encoding="utf-8"), plugin_only[:-len("\n}\n")] + (
            ',\n'
            '  "harnessSkillLocks": {\n'
            '    "writing": {\n'
            f'      "commit": "{"d" * 40}",\n'
            '      "tag": "v1.0.0"\n'
            '    }\n'
            '  }\n'
            '}\n'
        ))
        self.assertFalse(self.refresh())

    def test_unstable_skill_release_preserves_prior_bytes(self):
        release = self.responses[self.skill_release_path]
        for case in ({**release, "draft": True}, {**release, "prerelease": True}, {**release, "tag_name": "v1.0.0-rc1"},
                     {**release, "tag_name": "1.0.0"}, {**release, "tag_name": "v1.0"}):
            with self.subTest(case=case):
                self.responses[self.skill_release_path] = case
                with self.assertRaises(ValueError):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_upstream_skill_added_fails_naming_it_and_preserves_lock(self):
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS, "translator": TOOLS})
        with self.assertRaisesRegex(ValueError, "added upstream: translator"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_upstream_skill_removed_fails_naming_it_and_preserves_lock(self):
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS})
        with self.assertRaisesRegex(ValueError, "removed upstream: style-guide"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_widened_allowed_tools_fails_with_both_values_and_preserves_lock(self):
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS + " Bash", "style-guide": TOOLS})
        with self.assertRaises(ValueError) as raised:
            self.refresh()
        message = str(raised.exception)
        self.assertIn("humanizer", message)
        self.assertIn(f"declared {TOOLS!r}", message)
        self.assertIn(f"upstream {TOOLS + ' Bash'!r}", message)
        self.assertNotIn("style-guide", message)
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_unreviewed_capability_frontmatter_fails_naming_the_key(self):
        for key, block in (("hooks", "hooks:\n  PreToolUse: []\n"), ("shell", "shell: bash\n")):
            with self.subTest(key=key):
                self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS},
                                      extra_frontmatter={"humanizer": block})
                with self.assertRaisesRegex(ValueError, f"humanizer frontmatter adds unreviewed keys: {key}"):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_duplicated_allowed_tools_line_fails(self):
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS},
                              extra_frontmatter={"style-guide": "allowed-tools: Bash\n"})
        with self.assertRaisesRegex(ValueError, "style-guide duplicate frontmatter key 'allowed-tools'"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_non_regular_or_nested_skill_entries_fail(self):
        cases = {
            "symlink": {"path": "skills/humanizer/link", "mode": "120000", "type": "blob", "sha": "8" * 40},
            "executable": {"path": "skills/humanizer/run.sh", "mode": "100755", "type": "blob", "sha": "8" * 40},
            "submodule": {"path": "skills/humanizer/vendor", "mode": "160000", "type": "commit", "sha": "8" * 40},
            "nested skill": {"path": "skills/humanizer/inner/SKILL.md", "mode": "100644", "type": "blob", "sha": "8" * 40},
        }
        for case, entry in cases.items():
            with self.subTest(case=case):
                self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS}, extra_entries=[entry])
                with self.assertRaisesRegex(ValueError, entry["path"]):
                    self.refresh()
                self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_truncated_tree_listing_fails(self):
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS}, truncated=True)
        with self.assertRaisesRegex(ValueError, "truncated"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), self.previous)

    def test_skill_drift_keeps_reviewed_skill_pin_and_still_moves_plugin_pins(self):
        self.start_from_reviewed_skill_pin()
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS, "style-guide": TOOLS},
                              extra_frontmatter={"humanizer": "hooks:\n  PreToolUse: []\n"})
        with self.assertRaisesRegex(UPDATER.SkillDriftError, "writing: .*humanizer frontmatter adds unreviewed keys: hooks"):
            self.refresh()
        self.assertEqual(self.pin(), {"tag": "plugin.v1.2.3", "commit": "a" * 40})
        self.assertEqual(self.locked()["harnessSkillLocks"], {"writing": {"tag": "v0.9.0", "commit": "c" * 40}})

    def test_unreachable_skill_release_keeps_reviewed_skill_pin(self):
        self.start_from_reviewed_skill_pin()

        def fetch(endpoint):
            if endpoint == self.skill_release_path:
                raise subprocess.CalledProcessError(1, "gh", stderr="not found")
            return self.responses[endpoint]

        with self.assertRaises(UPDATER.SkillDriftError):
            UPDATER.update_lock(self.root, fetch)
        self.assertEqual(self.pin(), {"tag": "plugin.v1.2.3", "commit": "a" * 40})
        self.assertEqual(self.locked()["harnessSkillLocks"], {"writing": {"tag": "v0.9.0", "commit": "c" * 40}})

    def test_drift_with_unchanged_plugin_pins_still_reports_without_rewriting(self):
        self.start_from_reviewed_skill_pin()
        self.responses[self.release_path]["tag_name"] = "plugin.v1.2.2"
        self.responses[self.ref_path.replace("1.2.3", "1.2.2")] = {"ref": "refs/tags/plugin.v1.2.2", "object": {"type": "commit", "sha": "0" * 40}}
        self.publish_upstream({"grammar-checker": TOOLS, "humanizer": TOOLS})
        before = self.lock.read_bytes()
        with self.assertRaisesRegex(UPDATER.SkillDriftError, "removed upstream: style-guide"):
            self.refresh()
        self.assertEqual(self.lock.read_bytes(), before)

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
