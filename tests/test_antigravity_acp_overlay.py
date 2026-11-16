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

STAND_IN_TOOL_FILTER = '''
import dataclasses
import enum
import types


class BuiltinTools(enum.Enum):
    RUN_COMMAND = "run_command"
    VIEW_FILE = "view_file"
    START_SUBAGENT = "start_subagent"

    @classmethod
    def all_tools(cls):
        return list(cls)


sdk_types_module = types.SimpleNamespace(BuiltinTools=BuiltinTools)


def _tool_name_to_builtin(name):
    try:
        return sdk_types_module.BuiltinTools(name.strip())
    except ValueError:
        return None


@dataclasses.dataclass(frozen=True)
class ToolFilterConfig:
    enabled_tools: tuple = None
    disabled_tools: tuple = None

    def is_empty(self):
        return self.enabled_tools is None and self.disabled_tools is None

    def to_dict(self):
        result = {}
        if self.enabled_tools is not None:
            result["enabledTools"] = list(self.enabled_tools)
        if self.disabled_tools is not None:
            result["disabledTools"] = list(self.disabled_tools)
        return result

    @classmethod
    def from_dict(cls, data):
        def names(value):
            return None if value is None else tuple(value)
        return cls(enabled_tools=names(data.get("enabledTools")), disabled_tools=names(data.get("disabledTools")))

    def resolve_disabled_builtins(self):
        if self.is_empty():
            return set()
        if self.enabled_tools is not None:
            allowed = {_tool_name_to_builtin(n) for n in self.enabled_tools} - {None}
            allowed -= {_tool_name_to_builtin(n) for n in self.disabled_tools or ()}
            return set(sdk_types_module.BuiltinTools.all_tools()) - allowed
        return {_tool_name_to_builtin(n) for n in self.disabled_tools or ()} - {None}
'''

counter = itertools.count()


class OverlayCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        for name in ("ANTIGRAVITY_ACP_RULES_DIR", "ANTIGRAVITY_ACP_PLUGIN_SKILLS",
                     "ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE"):
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

    def test_t3_file_composes_with_baseline_and_client_additions(self):
        addition = self.dir / "antigravity.md"
        addition.write_text("# T3 delegation\nt3 policy\n")
        os.environ["ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE"] = str(addition)
        (self.rules / "nix-config-01.md").write_text(FRONTMATTER + "baseline\n")
        for baseline in (False, True):
            for client in (None, "client line one\n\n  indented line two"):
                with self.subTest(baseline=baseline, client=client):
                    if baseline:
                        self.point_at_rules()
                    else:
                        os.environ.pop("ANTIGRAVITY_ACP_RULES_DIR", None)
                    expected = ("baseline\n\n" if baseline else "") + addition.read_text()
                    if client:
                        expected = expected.rstrip("\n") + "\n\n" + client
                    self.assertEqual(self.prompt.extract_system_prompt({"append": client}), expected)

    def test_configured_missing_t3_file_raises_instead_of_omitting_it(self):
        os.environ["ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE"] = str(self.dir / "missing.md")
        with self.assertRaises(FileNotFoundError):
            self.prompt.extract_system_prompt({"append": "client text"})

    def test_unset_variable_keeps_the_shipped_result_without_a_warning(self):
        for value in (None, ""):
            with self.subTest(t3_file=value), self.assertNoLogs(level="WARNING"):
                if value is not None:
                    os.environ["ANTIGRAVITY_ACP_T3_INSTRUCTIONS_FILE"] = value
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


class ToolFilterOverlayTest(OverlayCase):
    def setUp(self):
        super().setUp()
        self.filters = self.load("tool_filter", STAND_IN_TOOL_FILTER)
        self.tools = self.filters.BuiltinTools

    def disabled(self, **fields):
        return self.filters.ToolFilterConfig(**fields).resolve_disabled_builtins()

    def test_no_filter_disables_only_start_subagent(self):
        self.assertEqual(self.disabled(), {self.tools.START_SUBAGENT})

    def test_a_denylist_keeps_its_tools_and_adds_start_subagent(self):
        self.assertEqual(
            self.disabled(disabled_tools=("run_command",)),
            {self.tools.RUN_COMMAND, self.tools.START_SUBAGENT},
        )

    def test_an_allowlist_naming_start_subagent_still_disables_it(self):
        self.assertEqual(
            self.disabled(enabled_tools=("start_subagent", "view_file")),
            {self.tools.RUN_COMMAND, self.tools.START_SUBAGENT},
        )

    def test_a_filter_restored_from_session_metadata_disables_start_subagent(self):
        restored = self.filters.ToolFilterConfig.from_dict({"disabledTools": []})
        self.assertEqual(restored.resolve_disabled_builtins(), {self.tools.START_SUBAGENT})

    def test_the_stored_filter_stays_as_the_client_sent_it(self):
        config = self.filters.ToolFilterConfig(enabled_tools=("view_file",))
        config.resolve_disabled_builtins()
        self.assertEqual(config.to_dict(), {"enabledTools": ["view_file"]})


if __name__ == "__main__":
    unittest.main()
