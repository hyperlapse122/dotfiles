"""Run the Antigravity ACP overlays against stand-ins for the shipped modules.

The runtime's own modules stay out of the repository. Each test writes an
invented module with the same function, copies the overlay beside it, and
appends the import line the repack tool appends, so the overlay rebinds the
function the way it does inside the archive.
"""

import importlib
import importlib.machinery
import importlib.util
import itertools
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
OVERLAYS = ROOT / "packages/antigravity-acp-overlay"
AGENT_INSTRUCTIONS = ROOT / "scripts/agent-instructions"

FRONTMATTER = "---\ntrigger: always_on\n---\n\n"

STAND_IN_PROMPT = '''
def extract_system_prompt(kwargs):
    append = (kwargs or {}).get("append")
    if isinstance(append, str) and append.strip():
        return append.strip()
    return None
'''

STAND_IN_PATHS = """
def global_skills_paths():
    return ("/home/stand-in/config/skills", "/home/stand-in/antigravity-cli/skills")
"""

counter = itertools.count()


class OverlayCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        for name in ("ANTIGRAVITY_ACP_RULES_DIR", "ANTIGRAVITY_ACP_PLUGIN_SKILLS"):
            os.environ.pop(name, None)

    def load(self, module, stand_in):
        """Import a stand-in shipped module whose tail imports its overlay."""
        package = f"stand_in_{next(counter)}"
        root = self.dir / "modules" / package
        root.mkdir(parents=True)
        (root / "__init__.py").write_text("")
        (root / f"{module}.py").write_text(stand_in + f"\nfrom . import {module}_overlay\n")
        shutil.copy(OVERLAYS / f"{module}_overlay.py", root)
        sys.path.insert(0, str(root.parent))
        self.addCleanup(sys.path.remove, str(root.parent))
        self.addCleanup(
            lambda: [sys.modules.pop(name) for name in list(sys.modules) if name.split(".")[0] == package]
        )
        return importlib.import_module(f"{package}.{module}")


class SystemPromptOverlayTest(OverlayCase):
    def setUp(self):
        super().setUp()
        self.rules = self.dir / "rules"
        self.rules.mkdir()
        self.prompt = self.load("system_prompt", STAND_IN_PROMPT)

    def point_at_rules(self):
        os.environ["ANTIGRAVITY_ACP_RULES_DIR"] = str(self.rules)

    def test_rules_in_name_order_then_the_client_append_without_frontmatter(self):
        (self.rules / "nix-config-02.md").write_text(FRONTMATTER + "# Two\nsecond\n")
        (self.rules / "nix-config-01.md").write_text(FRONTMATTER + "# One\nfirst\n")
        (self.rules / "notes.md").write_text("# Not a rule file\n")
        self.point_at_rules()
        self.assertEqual(
            self.prompt.extract_system_prompt({"append": "client text"}),
            "# One\nfirst\n# Two\nsecond\n\nclient text",
        )

    def test_client_append_survives_intact_after_the_rules(self):
        (self.rules / "nix-config-01.md").write_text(FRONTMATTER + "# One\nfirst\n")
        self.point_at_rules()
        append = "line one\n\n  indented line two\n- item"
        self.assertEqual(self.prompt.extract_system_prompt({"append": append}), "# One\nfirst\n\n" + append)

    def test_rules_alone_when_the_client_sends_no_append(self):
        (self.rules / "nix-config-01.md").write_text(FRONTMATTER + "# One\nfirst\n")
        self.point_at_rules()
        self.assertEqual(self.prompt.extract_system_prompt({}), "# One\nfirst\n")
        self.assertEqual(self.prompt.extract_system_prompt(None), "# One\nfirst\n")

    def test_unset_variable_keeps_the_shipped_result_without_a_warning(self):
        with self.assertNoLogs(level="WARNING"):
            self.assertEqual(self.prompt.extract_system_prompt({"append": "client text"}), "client text")
            self.assertIsNone(self.prompt.extract_system_prompt({}))

    def test_missing_directory_keeps_the_shipped_result_and_warns_once(self):
        os.environ["ANTIGRAVITY_ACP_RULES_DIR"] = str(self.dir / "absent")
        with self.assertLogs(level="WARNING") as logs:
            self.assertEqual(self.prompt.extract_system_prompt({"append": "client text"}), "client text")
        self.assertEqual(len(logs.records), 1)

    def test_directory_without_rule_files_keeps_the_shipped_result_and_warns_once(self):
        (self.rules / "notes.md").write_text("# Not a rule file\n")
        self.point_at_rules()
        with self.assertLogs(level="WARNING") as logs:
            self.assertEqual(self.prompt.extract_system_prompt({"append": "client text"}), "client text")
        self.assertEqual(len(logs.records), 1)

    def test_rule_file_without_the_expected_frontmatter_is_included_unchanged(self):
        other = "---\ntrigger: manual\n---\n\n# Manual\nbody\n"
        (self.rules / "nix-config-01.md").write_text("# Bare\nbody\n")
        (self.rules / "nix-config-02.md").write_text(other)
        self.point_at_rules()
        self.assertEqual(self.prompt.extract_system_prompt(None), "# Bare\nbody\n" + other)


    def test_frontmatter_matches_the_one_agent_instructions_writes(self):
        loader = importlib.machinery.SourceFileLoader("agent_instructions", str(AGENT_INSTRUCTIONS))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        instructions = importlib.util.module_from_spec(spec)
        loader.exec_module(instructions)
        self.assertEqual(
            self.prompt.system_prompt_overlay.FRONTMATTER.encode("utf-8"),
            instructions.RULE_FRONTMATTER,
            "the overlay's FRONTMATTER differs from RULE_FRONTMATTER in scripts/agent-instructions",
        )


class PathsOverlayTest(OverlayCase):
    SHIPPED = ("/home/stand-in/config/skills", "/home/stand-in/antigravity-cli/skills")

    def setUp(self):
        super().setUp()
        self.paths = self.load("paths", STAND_IN_PATHS)

    def test_directory_replaces_the_first_path_and_leaves_the_second(self):
        os.environ["ANTIGRAVITY_ACP_PLUGIN_SKILLS"] = str(self.dir)
        self.assertEqual(self.paths.global_skills_paths(), (str(self.dir), self.SHIPPED[1]))

    def test_unset_variable_leaves_the_pair_alone(self):
        self.assertEqual(self.paths.global_skills_paths(), self.SHIPPED)

    def test_variable_that_is_not_a_directory_leaves_the_pair_alone(self):
        os.environ["ANTIGRAVITY_ACP_PLUGIN_SKILLS"] = str(self.dir / "absent")
        self.assertEqual(self.paths.global_skills_paths(), self.SHIPPED)
        (self.dir / "file").write_text("")
        os.environ["ANTIGRAVITY_ACP_PLUGIN_SKILLS"] = str(self.dir / "file")
        self.assertEqual(self.paths.global_skills_paths(), self.SHIPPED)


if __name__ == "__main__":
    unittest.main()
