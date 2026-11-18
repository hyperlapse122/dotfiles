"""Drive the source catalog command with minimal pinned source layouts."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/harness-agents"
ROLE = """
                (
                    "researcher".to_string(),
                    AgentRoleConfig {
                        description: Some(r#"Follow links such as https://example.test."#.to_string()),
                        config_file: Some("researcher.toml".to_string().parse().unwrap_or_default()),
                        nickname_candidates: None,
                    },
                ),
"""
REGISTRY = """
pub const DEFAULT_ROLE_NAME: &str = "default";

mod built_in {
    use super::*;
    pub(super) fn configs() -> &'static BTreeMap<String, AgentRoleConfig> {
        static CONFIG: LazyLock<BTreeMap<String, AgentRoleConfig>> = LazyLock::new(|| {
            BTreeMap::from([
                (
                    DEFAULT_ROLE_NAME.to_string(),
                    AgentRoleConfig {
                        description: Some("Default agent.".to_string()),
                        config_file: None,
                        nickname_candidates: None,
                    }
                ),
                // ("ignored".to_string(), find_config()),
""" + ROLE + """
            ])
        });
        &CONFIG
    }

    pub(super) fn config_file_contents(path: &Path) -> Option<&'static str> {
        const RESEARCHER: &str = include_str!("../../assets/agent/builtins/researcher.toml");
        match path.to_str()? {
            "researcher.toml" => Some(RESEARCHER),
            _ => None,
        }
    }
}

#[cfg(test)]
#[path = "role_tests.rs"]
mod tests;
"""
PI_BUILTINS = """
import codemodeExtension from "./codemode/index.ts";
import llamaExtension from "./llama/index.ts";
import mcpExtension from "./mcp/index.ts";
import toolSearchExtension from "./tool-search/index.ts";

export const builtInExtensions: InlineExtension[] = [
    { name: "llama.cpp", factory: llamaExtension, builtin: true },
    { name: "codemode", factory: codemodeExtension, replaceable: true, builtin: true },
    { name: "tool-search", factory: toolSearchExtension, replaceable: true, builtin: true },
    { name: "mcp", factory: mcpExtension, replaceable: true, builtin: true },
];
"""
PI_README = "Pi ships with powerful defaults but skips features like sub-agents and plan mode."


class HarnessAgentsTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.source = self.root / "source"
        self.pin = self.root / "pin.json"
        self.pin.write_text(json.dumps({"version": "1.2.3", "source": {"rev": "a" * 40}}))

    def fixture(self, path, contents):
        full = self.source / path
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(contents)

    def codex_source(self, registry=REGISTRY):
        self.fixture("codex-rs/Cargo.toml", '[workspace.package]\nversion = "1.2.3"\n')
        self.fixture("codex-rs/core/src/agent/role.rs", registry)
        self.fixture(
            "codex-rs/core/assets/agent/builtins/researcher.toml",
            'model = "test-model"\nmodel_reasoning_effort = "high"\n'
            'developer_instructions = "PRIVATE PROMPT"\n[features]\nweb_search = false\n',
        )

    def run_catalog(self, harness, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), harness, "--source", str(self.source),
             "--pin", str(self.pin), *args],
            capture_output=True,
            text=True,
        )

    def assert_catalog_kept(self, harness, error):
        output = self.root / "catalog.json"
        output.write_text("previous catalog")
        result = self.run_catalog(harness, "-o", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(error, result.stderr)
        self.assertEqual(output.read_text(), "previous catalog")

    def pi_source(self, *, readme=PI_README, builtins=PI_BUILTINS):
        self.fixture("packages/coding-agent/package.json", '{"version":"1.2.3"}')
        self.fixture("packages/coding-agent/README.md", readme)
        self.fixture("packages/coding-agent/src/extensions/index.ts", builtins)

    def test_codex_role_settings_and_inheritance(self):
        self.codex_source()
        result = self.run_catalog("codex")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["agents"], [
            {"agentType": "default", "whenToUse": "Default agent.", "model": {"inherited": True}},
            {
                "agentType": "researcher",
                "whenToUse": "Follow links such as https://example.test.",
                "model": "test-model",
                "modelReasoningEffort": "high",
                "features": {"web_search": False},
            },
        ])

    def test_codex_unknown_registration_does_not_replace_previous_catalog(self):
        self.codex_source(REGISTRY.replace(ROLE, ROLE + "                dynamic_role(),\n"))
        self.assert_catalog_kept("codex", "dynamic_role")

    def test_codex_raw_description_cannot_hide_an_unsupported_role(self):
        unknown = ROLE.replace("nickname_candidates: None,", "nickname_candidates: Some(vec![]),")
        second = ROLE.replace('"researcher".to_string()', '"second".to_string()')
        self.codex_source(REGISTRY.replace(ROLE, unknown + second))
        self.assert_catalog_kept("codex", "unsupported declaration")

    def test_codex_unknown_role_setting_keeps_previous_catalog(self):
        self.codex_source()
        self.fixture(
            "codex-rs/core/assets/agent/builtins/researcher.toml",
            'unknown_setting = "a new policy"\n',
        )
        self.assert_catalog_kept("codex", "unknown_setting")

    def test_pi_new_builtin_requires_roster_verification(self):
        self.pi_source(
            builtins=PI_BUILTINS.replace("];", '    { name: "delegation", factory: delegate, builtin: true },\n];'),
        )
        self.assert_catalog_kept("pi", "built-in extensions changed")

    def test_pi_changed_factory_keeps_previous_catalog(self):
        self.pi_source(
            builtins=PI_BUILTINS.replace("./codemode/index.ts", "../../examples/extensions/subagent/index.ts"),
        )
        self.assert_catalog_kept("pi", "built-in extensions changed")

    def test_pi_missing_absence_statement_keeps_previous_catalog(self):
        self.pi_source(readme="Pi ships with powerful defaults.")
        self.assert_catalog_kept("pi", "no longer confirms the absence")


if __name__ == "__main__":
    unittest.main()
