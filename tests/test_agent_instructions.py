import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


HEADING = "## Writing skills"
CLEANUP_HEADING = "## Temporary containers and local Kubernetes"
RUNTIME_HEADING = "## Container runtime"
SKILLS = ("`humanizer`", "`grammar-checker`", "`style-guide`", "`ce-noslop`")
EXCLUSIONS = ("progress notes", "questions to the user", "reports a subagent returns to its caller",
              "code and config", "code comments and docstrings", "verbatim quotes",
              "text the user asked to post as written")
BASELINE_ADAPTERS = {
    "claude": "private_dot_claude/private_empty_CLAUDE.md.tmpl",
    "codex": "private_dot_codex/private_empty_AGENTS.md.tmpl",
    "pi": "private_dot_pi/private_agent/private_empty_AGENTS.md.tmpl",
    "grok": "private_dot_grok/private_empty_AGENTS.md.tmpl",
    "antigravity": "private_dot_gemini/private_empty_GEMINI.md.tmpl",
}
T3_ADAPTERS = {harness: f"private_dot_t3/private_userdata/private_instructions/private_empty_{harness}.md.tmpl"
               for harness in ("claude", "codex", "pi")}


def instruction_block(text, heading=HEADING):
    start = text.find(heading)
    if start < 0:
        return ""
    end = re.compile(r"^#{1,2} ", re.MULTILINE).search(text, start + len(heading))
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

        for context, adapters in (("baseline", BASELINE_ADAPTERS), ("t3", T3_ADAPTERS)):
            for harness, adapter in adapters.items():
                shutil.copy2(repo / "home" / adapter, source / ".chezmoitemplates" / f"{context}-{harness}")

        def render(context, harness, operating_system=None):
            data = "." if operating_system is None else f'(dict "chezmoi" (dict "os" "{operating_system}"))'
            template = '{{ template "' + f"{context}-{harness}" + '" ' + data + ' }}'
            result = subprocess.run(
                [chezmoi, "--config", str(config), "--source", str(source), "--destination", str(home),
                 "--cache", str(root / "chezmoi-cache"), "--persistent-state", str(root / "chezmoi-state"),
                 "--no-tty", "execute-template"],
                env=env, input=template,
                capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60)
            if result.returncode != 0:
                raise AssertionError(f"{context}/{harness}/{operating_system}\n" + result.stdout + result.stderr)
            return result.stdout

        operating_systems = (None, "darwin", "windows", "linux")
        cls.baselines = {os_name: {harness: render("baseline", harness, os_name) for harness in BASELINE_ADAPTERS}
                         for os_name in operating_systems}
        cls.t3_additions = {os_name: {harness: render("t3", harness, os_name) for harness in T3_ADAPTERS}
                           for os_name in operating_systems}

    def test_every_harness_renders_the_block_once_with_identical_text(self):
        expected = instruction_block(self.baselines[None]["claude"])
        self.assertTrue(expected.strip(), self.baselines[None]["claude"])
        for os_name, baseline in self.baselines.items():
            for harness, rendered in baseline.items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertEqual(rendered.count(HEADING), 1, rendered)
                    self.assertEqual(instruction_block(rendered), expected)
                    self.assertTrue(rendered.startswith(HEADING), repr(rendered[:80]))
                    self.assertNotIn("\n\n\n", rendered)

    def test_block_names_the_writing_skills_and_every_exclusion(self):
        block = instruction_block(self.baselines[None]["claude"])
        for skill in SKILLS:
            self.assertIn(skill, block)
        self.assertLess(block.index("`humanizer`"), block.index("`grammar-checker`"))
        excluded = next((line for line in block.splitlines() if "Out of scope" in line), "")
        for exclusion in EXCLUSIONS:
            self.assertIn(exclusion, excluded)

    def test_t3_additions_contain_no_part_of_the_block(self):
        lines = [line.strip() for line in instruction_block(self.baselines[None]["claude"]).splitlines() if line.strip()]
        for os_name, additions in self.t3_additions.items():
            for harness, rendered in additions.items():
                with self.subTest(os=os_name, harness=harness):
                    for text in (*lines, *SKILLS):
                        self.assertNotIn(text, rendered)

    def test_cleanup_policy_is_shared_once_and_not_duplicated_in_t3(self):
        expected = instruction_block(self.baselines[None]["claude"], CLEANUP_HEADING)
        self.assertTrue(expected.strip())
        for safeguard in ("identify the local runtime or cluster endpoint",
                          "clusters, containers, images, volumes, networks, build caches, and temporary data",
                          "whether run by a user or an agent", "Do not use a global prune or runtime reset",
                          "Do not delete remote resources", "success, failure, and orderly cancellation",
                          "zero task-owned volumes", "ownership cannot be established",
                          "Check host disk-space reclamation separately", "leave the runtime running"):
            self.assertIn(safeguard, expected)
        for os_name, baseline in self.baselines.items():
            for harness, rendered in baseline.items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertEqual(rendered.count(CLEANUP_HEADING), 1)
                    self.assertEqual(instruction_block(rendered, CLEANUP_HEADING), expected)
        for os_name, additions in self.t3_additions.items():
            for harness, rendered in additions.items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertNotIn(CLEANUP_HEADING, rendered)
                    for line in expected.splitlines():
                        if line.strip():
                            self.assertNotIn(line, rendered)

    def test_runtime_guidance_is_shared_once_and_selected_by_host(self):
        for os_name in ("darwin", "windows", "linux"):
            expected = instruction_block(self.baselines[os_name]["claude"], RUNTIME_HEADING)
            for harness, rendered in self.baselines[os_name].items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertEqual(rendered.count(RUNTIME_HEADING), 0 if os_name == "linux" else 1)
                    self.assertEqual(instruction_block(rendered, RUNTIME_HEADING), expected)
                    if os_name == "darwin":
                        self.assertIn("Apple", expected)
                        self.assertIn("`container`", expected)
                        self.assertIn("by default for temporary container-related development work", expected)
                        for workload in ("image builds", "execution", "testing", "image, network, and volume operations"):
                            self.assertIn(workload, expected)
                        self.assertNotIn("Podman", rendered)
                    elif os_name == "windows":
                        self.assertIn("Podman", expected)
                        self.assertIn("Podman Desktop", expected)
                        self.assertIn("Do not automate engine provisioning", expected)
                        self.assertNotIn("Apple", rendered)
                        self.assertNotIn("`container`", rendered)
                    else:
                        for runtime in ("Apple", "`container`", "Podman"):
                            self.assertNotIn(runtime, rendered)

    def test_native_host_matches_its_explicit_os_context(self):
        os_name = "windows" if sys.platform == "win32" else sys.platform
        for context, renderings in (("baseline", self.baselines), ("t3", self.t3_additions)):
            for harness, rendered in renderings[None].items():
                with self.subTest(context=context, os=os_name, harness=harness):
                    self.assertEqual(rendered, renderings[os_name][harness])

    def test_macos_checks_installed_capabilities_before_agreeing_on_an_alternative(self):
        block = instruction_block(self.baselines["darwin"]["claude"], RUNTIME_HEADING)
        for text in ("installed `container` version", "capabilities", "required operation",
                     "concrete limitation", "agree on an alternative with the user",
                     "before using another runtime or installing compatibility tools"):
            self.assertIn(text, block)

    def test_runtime_startup_is_on_demand_only(self):
        for os_name in ("darwin", "windows"):
            block = instruction_block(self.baselines[os_name]["claude"], RUNTIME_HEADING)
            with self.subTest(os=os_name):
                for text in ("only when an active task needs it", "Do not start it during configuration application",
                             "or enable startup at login"):
                    self.assertIn(text, block)
                if os_name == "darwin":
                    self.assertIn("manually with `container system start`", block)

    def test_t3_additions_contain_no_runtime_baseline_on_any_host(self):
        runtime_lines = {line for os_name in ("darwin", "windows")
                         for line in instruction_block(self.baselines[os_name]["claude"], RUNTIME_HEADING).splitlines()
                         if line.strip()}
        for os_name, additions in self.t3_additions.items():
            for harness, rendered in additions.items():
                with self.subTest(os=os_name, harness=harness):
                    for text in (*runtime_lines, "Apple", "Podman", "container system start"):
                        self.assertNotIn(text, rendered)

    def test_delegation_policy_is_only_in_t3_additions(self):
        heading = "## T3 delegation"
        for os_name, additions in self.t3_additions.items():
            for harness, rendered in additions.items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertEqual(rendered.count(heading), 1)
                    for text in ("delegate_task", "same-provider", "agents dispatched by skills", "higher-priority",
                                 "native subagent", "top-level thread", "acpx", "cross-model",
                                 "CE's existing", "self-contained", "target.options",
                                 "Do not fabricate", "inline"):
                        self.assertIn(text, rendered)
                    self.assertNotIn("prefer T3 Code's", rendered)
                    self.assertNotIn("explicit tool requirements; this preference does not override them", rendered)
                    self.assertNotIn("use a native subagent tool", rendered)
        for os_name, baseline in self.baselines.items():
            for harness, rendered in baseline.items():
                with self.subTest(os=os_name, harness=harness):
                    self.assertNotIn(heading, rendered)
                    self.assertNotIn("delegate_task", rendered)


if __name__ == "__main__":
    unittest.main()
