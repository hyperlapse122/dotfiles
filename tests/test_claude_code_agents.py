"""Drive claude-code-agents against small synthetic Claude Code binaries.

Each test writes a fake `claude` on `PATH` with a `.claude-wrapped` beside it
whose bytes imitate the Bun module layout of a real release: a `// @bun`
header per module, a `// Version:` line, and minified agent object literals.
The real binary is covered by the catalog check, which re-extracts the pinned
package and compares the result with the committed catalog.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-code-agents"


def module(body, version="9.9.9"):
    return f"// @bun @bytecode\n// (c) fixture\n\n// Version: {version}\n{body}\n\x00"


def agent(agent_type, extra=""):
    return (
        "{agentType:" + agent_type + ",whenToUse:\"use it\"," + extra
        + "source:\"built-in\",baseDir:\"built-in\",getSystemPrompt:()=>\"secret prompt\"}"
    )


# The three agents every release must contain, defined with literal values.
BASE = "var a=" + agent('"general-purpose"', 'tools:["*"],') + ",b=" + agent(
    '"Explore"', 'disallowedTools:["Edit"],model:"inherit",'
) + ",c=" + agent('"Plan"', "tools:b.tools,")


class ClaudeCodeAgentsTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        claude = self.bin_dir / "claude"
        claude.write_text("#!/bin/sh\nexit 0\n")
        claude.chmod(0o755)
        self.output = self.root / "agents.json"

    def run_agents(self, *modules):
        (self.bin_dir / ".claude-wrapped").write_bytes(b"\x7fELF" + "".join(modules).encode("utf-8"))
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{env.get('PATH', '')}"
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output)],
            env=env,
            capture_output=True,
            text=True,
        )

    def catalog(self, *modules):
        proc = self.run_agents(*modules)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(self.output.read_text())

    def entry(self, catalog, agent_type):
        return next(a for a in catalog["agents"] if a["agentType"] == agent_type)

    def assert_fails(self, message, *modules):
        self.output.write_text("previous\n")
        proc = self.run_agents(*modules)
        self.assertEqual(proc.returncode, 1)
        self.assertIn(message, proc.stderr)
        self.assertEqual(self.output.read_text(), "previous\n")

    def test_writes_sorted_entries_with_version(self):
        catalog = self.catalog(module(BASE))
        self.assertEqual(catalog["version"], "9.9.9")
        self.assertEqual([a["agentType"] for a in catalog["agents"]], ["Explore", "Plan", "general-purpose"])
        self.assertEqual(
            self.entry(catalog, "Explore"),
            {
                "agentType": "Explore",
                "whenToUse": {"text": "use it", "interpolated": False},
                "tools": None,
                "disallowedTools": ["Edit"],
                "model": "inherit",
            },
        )
        self.assertEqual(self.entry(catalog, "general-purpose")["tools"], ["*"])

    def test_resolves_local_names_inside_their_own_module(self):
        other = module('var ft="NotTheTool";export{ft};')
        mine = module('var ft="Agent",l4=["Write","NotebookEdit"];' + BASE.replace('["Edit"]', "[ft,...l4]"))
        catalog = self.catalog(other, mine)
        self.assertEqual(self.entry(catalog, "Explore")["disallowedTools"], ["Agent", "Write", "NotebookEdit"])

    def test_resolves_imports_through_the_single_exporting_module(self):
        exporter = module('var x="ExitPlanMode";export{x as q};')
        importer = module('import{q as ft}from"/$bunfs/root/chunk-x.js";' + BASE.replace('["Edit"]', "[ft]"))
        catalog = self.catalog(exporter, importer)
        self.assertEqual(self.entry(catalog, "Explore")["disallowedTools"], ["ExitPlanMode"])

    def test_member_reference_to_an_absent_field_is_absent(self):
        catalog = self.catalog(module(BASE))
        self.assertIsNone(self.entry(catalog, "Plan")["tools"])

    def test_agent_type_held_in_a_variable(self):
        catalog = self.catalog(module('var mT="fork";' + BASE + ",d=" + agent("mT")))
        self.assertIn("fork", [a["agentType"] for a in catalog["agents"]])

    def test_getters_are_recorded_as_conditional(self):
        guide = agent('"claude-code-guide"', 'get tools(){return f()?["Read"]:["Glob"]},get model(){return g()},')
        catalog = self.catalog(module(BASE + ",d=" + guide))
        entry = self.entry(catalog, "claude-code-guide")
        self.assertEqual(entry["tools"], {"conditional": True})
        self.assertEqual(entry["model"], {"conditional": True})

    def test_interpolated_description_keeps_its_placeholder(self):
        guide = agent('"claude-code-guide"').replace('whenToUse:"use it"', "whenToUse:`continue it via ${Mn}.`")
        catalog = self.catalog(module('var Mn="SendMessage";' + BASE + ",d=" + guide))
        self.assertEqual(
            self.entry(catalog, "claude-code-guide")["whenToUse"],
            {"text": "continue it via ${Mn}.", "interpolated": True},
        )

    def test_other_built_in_objects_are_not_agents(self):
        style = '{name:"Concise",source:"built-in",description:"terse"}'
        factory = 'var rbo=(e)=>({agentType:e||"teammate",source:"built-in"});'
        catalog = self.catalog(module(factory + BASE + ",s=" + style))
        self.assertEqual(len(catalog["agents"]), 3)

    def test_output_omits_system_prompts(self):
        self.catalog(module(BASE))
        self.assertNotIn("secret prompt", self.output.read_text())

    def test_unresolved_reference_fails_and_keeps_the_previous_file(self):
        self.assert_fails("Explore: disallowedTools: ft: no definition or import", module(BASE.replace('["Edit"]', "[ft]")))

    def test_name_exported_by_two_modules_is_ambiguous(self):
        importer = module('import{q as ft}from"/$bunfs/root/chunk-x.js";' + BASE.replace('["Edit"]', "[ft]"))
        self.assert_fails(
            "ft: exported by 2 modules",
            module('var x="A";export{x as q};'),
            module('var y="B";export{y as q};'),
            importer,
        )

    def test_name_defined_twice_in_one_module_is_ambiguous(self):
        body = 'var ft="Agent";function z(){ft="Other"}' + BASE.replace('["Edit"]', "[ft]")
        self.assert_fails("ft: defined 2 times in one module", module(body))

    def test_missing_required_agent_fails(self):
        self.assert_fails("built-in agents not found: Plan", module(BASE.replace('"Plan"', '"Planner"')))

    def test_unparsed_built_in_marker_fails(self):
        hidden = '{whenToUse:"x",agentType:"hidden",source:"built-in",baseDir:"built-in"}'
        self.assert_fails("4 built-in agent markers but 3 agents parsed", module(BASE + ",h=" + hidden))


if __name__ == "__main__":
    unittest.main()
