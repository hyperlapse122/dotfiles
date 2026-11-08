import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


HEADING = "## Writing skills"
SKILLS = ("`humanizer`", "`grammar-checker`", "`style-guide`", "`ce-noslop`")
EXCLUSIONS = ("progress notes", "questions to the user", "reports a subagent returns to its caller",
              "code and config", "code comments and docstrings", "verbatim quotes",
              "text the user asked to post as written")
BASELINE_ADAPTERS = {
    "claude": "private_dot_claude/private_empty_CLAUDE.md.tmpl",
    "codex": "private_dot_codex/private_empty_AGENTS.md.tmpl",
    "pi": "private_dot_pi/private_agent/private_empty_AGENTS.md.tmpl",
    "grok": "private_dot_grok/private_empty_AGENTS.md.tmpl",
    "omp": "private_dot_omp/private_agent/private_empty_AGENTS.md.tmpl",
    "antigravity": "private_dot_gemini/private_empty_GEMINI.md.tmpl",
}
T3_ADAPTERS = {harness: f"private_dot_t3/private_userdata/private_instructions/private_empty_{harness}.md.tmpl"
               for harness in ("claude", "codex", "pi")}


def writing_block(text):
    start = text.find(HEADING)
    if start < 0:
        return ""
    end = re.compile(r"^#{1,2} ", re.MULTILINE).search(text, start + len(HEADING))
    return text[start:end.start() if end else len(text)].rstrip("\n") + "\n"


class AgentInstructionsTest(unittest.TestCase):
    """Renders the real shared template through each real adapter in a disposable source and home."""

    @classmethod
    def setUpClass(cls):
        repo = Path(__file__).resolve().parents[1]
        chezmoi = shutil.which("chezmoi")
        if chezmoi is None:
            raise AssertionError("Install chezmoi before running agent instruction tests")
        scratch = tempfile.TemporaryDirectory(prefix="agent instructions ' ")
        cls.addClassCleanup(scratch.cleanup)
        root = Path(scratch.name).resolve()
        home = root / "user's home"
        home.mkdir()
        source = root / "source"
        (source / ".chezmoitemplates").mkdir(parents=True)
        shutil.copy2(repo / "home/.chezmoitemplates/agent-instructions", source / ".chezmoitemplates")
        config = root / "chezmoi.toml"
        config.write_text("umask = 0o022\n", encoding="utf-8")
        env = {key: value for key, value in os.environ.items() if not key.upper().startswith("CHEZMOI_")}
        env.update({"HOME": str(home), "USERPROFILE": str(home),
                    "XDG_CONFIG_HOME": str(root / "config"), "XDG_CACHE_HOME": str(root / "cache"),
                    "XDG_DATA_HOME": str(root / "data"), "XDG_STATE_HOME": str(root / "state")})

        def render(adapter):
            result = subprocess.run(
                [chezmoi, "--config", str(config), "--source", str(source), "--destination", str(home),
                 "--cache", str(root / "chezmoi-cache"), "--persistent-state", str(root / "chezmoi-state"),
                 "--no-tty", "execute-template"],
                env=env, input=(repo / "home" / adapter).read_text(encoding="utf-8"),
                capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60)
            if result.returncode != 0:
                raise AssertionError(adapter + "\n" + result.stdout + result.stderr)
            return result.stdout

        cls.baseline = {harness: render(adapter) for harness, adapter in BASELINE_ADAPTERS.items()}
        cls.t3 = {harness: render(adapter) for harness, adapter in T3_ADAPTERS.items()}

    def test_every_harness_renders_the_block_once_with_identical_text(self):
        expected = writing_block(self.baseline["claude"])
        self.assertTrue(expected.strip(), self.baseline["claude"])
        for harness, rendered in self.baseline.items():
            with self.subTest(harness=harness):
                self.assertEqual(rendered.count(HEADING), 1, rendered)
                self.assertEqual(writing_block(rendered), expected)
                self.assertTrue(rendered.startswith(HEADING), repr(rendered[:80]))
                self.assertNotIn("\n\n\n", rendered)

    def test_block_names_the_writing_skills_and_every_exclusion(self):
        block = writing_block(self.baseline["claude"])
        for skill in SKILLS:
            self.assertIn(skill, block)
        self.assertLess(block.index("`humanizer`"), block.index("`grammar-checker`"))
        excluded = next((line for line in block.splitlines() if "Out of scope" in line), "")
        for exclusion in EXCLUSIONS:
            self.assertIn(exclusion, excluded)

    def test_t3_additions_contain_no_part_of_the_block(self):
        lines = [line.strip() for line in writing_block(self.baseline["claude"]).splitlines() if line.strip()]
        for harness, rendered in self.t3.items():
            with self.subTest(harness=harness):
                for text in (*lines, *SKILLS):
                    self.assertNotIn(text, rendered)

    def test_delegation_preference_is_only_in_t3_additions(self):
        heading = "## T3 delegation"
        for harness, rendered in self.t3.items():
            with self.subTest(harness=harness):
                self.assertEqual(rendered.count(heading), 1)
                for text in ("delegate_task", "same-provider", "skills", "higher-priority",
                             "native subagent", "top-level thread"):
                    self.assertIn(text, rendered)
        for harness, rendered in self.baseline.items():
            with self.subTest(harness=harness):
                self.assertNotIn(heading, rendered)
                self.assertNotIn("delegate_task", rendered)


if __name__ == "__main__":
    unittest.main()
