import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
PLUGIN_ID = "compound-engineering@compound-engineering-plugin"


class ClaudeTest(unittest.TestCase):
    def setUp(self):
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi)
        self.scratch = tempfile.TemporaryDirectory(prefix="claude ' 한글 ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home, self.source = self.root / "home", self.root / "source"
        self.home.mkdir()
        self.source.mkdir()
        for name in (".chezmoidata", ".chezmoitemplates", "private_dot_claude"):
            shutil.copytree(REPO / "home" / name, self.source / name)
        shutil.copy2(REPO / "home/.chezmoiignore", self.source / ".chezmoiignore")
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({"HOME": str(self.home), "USERPROFILE": str(self.home),
            "CLAUDE_CONFIG_DIR": str(self.root / "foreign-claude"),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"), "XDG_CONFIG_DIRS": str(self.root / "system"),
            "XDG_DATA_HOME": str(self.root / "data"), "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state")})
        self.claude = self.home / ".claude"
        self.settings = self.claude / "settings.json"

    def chez(self, *args):
        return subprocess.run([self.chezmoi, "--config", str(self.config), "--source", str(self.source),
            "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
            "--persistent-state", str(self.root / "chezmoi-state"), *args], env=self.env,
            capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=60)

    def apply(self):
        result = self.chez("apply", "--force", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_owned(self):
        data = json.loads(self.settings.read_text(encoding="utf-8"))
        self.assertEqual(data["language"], "korean")
        self.assertIs(data["autoMemoryEnabled"], False)
        self.assertIs(data["syncClaudeAiSkills"], False)
        self.assertIs(data["syncClaudeAiPlugins"], False)
        self.assertIs(data["disableClaudeAiConnectors"], True)
        self.assertEqual(data["env"]["DISABLE_AUTOUPDATER"], "1")
        self.assertEqual(data["env"]["CLAUDE_CODE_USE_POWERSHELL_TOOL"], "1")
        self.assertIs(data["enabledPlugins"][PLUGIN_ID], True)
        marketplace = data["extraKnownMarketplaces"]["compound-engineering-plugin"]
        self.assertIs(marketplace["autoUpdate"], False)
        self.assertEqual(marketplace["source"]["source"], "directory")
        self.assertEqual(Path(marketplace["source"]["path"]),
            self.home / ".local/share/dotfiles/harness-plugins/compound-engineering")
        return data

    def test_initial_apply_private_settings_and_shared_instructions(self):
        (self.source / ".chezmoitemplates/agent-instructions").write_text(
            'common-marker\n{{ if eq .harness "claude" }}claude-marker{{ end }}\n'
            '{{ if eq .harness "codex" }}foreign-marker{{ end }}\n'
            '{{ if eq .harness "pi" }}foreign-marker{{ end }}\n', encoding="utf-8")
        self.apply()
        self.assert_owned()
        instructions = (self.claude / "CLAUDE.md").read_text(encoding="utf-8")
        self.assertIn("common-marker", instructions)
        self.assertIn("claude-marker", instructions)
        self.assertNotIn("foreign-marker", instructions)
        self.assertFalse(Path(self.env["CLAUDE_CONFIG_DIR"]).exists())
        result = self.chez("dump", "--format=json", "--parent-dirs", str(self.settings), str(self.claude / "CLAUDE.md"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(result.stdout)
        for name, perm in ((".claude", 0o700), (".claude/settings.json", 0o600), (".claude/CLAUDE.md", 0o600)):
            self.assertEqual(state[name]["perm"], perm)
            if os.name != "nt":
                self.assertEqual((self.home / name).stat().st_mode & 0o777, perm)

    def test_reapply_preserves_unowned_state_and_existing_memory(self):
        self.claude.mkdir()
        original = {"language": "english", "autoMemoryEnabled": True, "model": "owner-model",
            "syncClaudeAiSkills": True, "syncClaudeAiPlugins": True, "disableClaudeAiConnectors": False,
            "env": {"DISABLE_AUTOUPDATER": "0", "OWNER_SETTING": "keep"},
            "enabledPlugins": {PLUGIN_ID: False, "unrelated@local": False},
            "extraKnownMarketplaces": {"other": {"source": {"source": "directory", "path": "/keep"}},
                "compound-engineering-plugin": {"source": {"source": "github", "repo": "stale/repo"},
                    "autoUpdate": True, "ownerExtra": "keep"}}}
        self.settings.write_text(json.dumps(original), encoding="utf-8")
        preserved = {".credentials.json": b"inert credential fixture", "sessions/state": b"session",
            "projects/example/memory/MEMORY.md": b"existing memory"}
        for name, content in preserved.items():
            path = self.claude / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        for _ in range(2):
            self.apply()
            data = self.assert_owned()
            self.assertEqual(data["model"], "owner-model")
            self.assertEqual(data["env"]["OWNER_SETTING"], "keep")
            self.assertIs(data["enabledPlugins"]["unrelated@local"], False)
            self.assertEqual(data["extraKnownMarketplaces"]["other"], original["extraKnownMarketplaces"]["other"])
            self.assertEqual(data["extraKnownMarketplaces"]["compound-engineering-plugin"]["ownerExtra"], "keep")
            for name, content in preserved.items():
                self.assertEqual((self.claude / name).read_bytes(), content)
        before = self.settings.read_bytes()
        self.apply()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_invalid_json_and_owned_container_shapes_preserve_file(self):
        self.claude.mkdir()
        cases = ['{"broken":', '[]', '{"env":false}', '{"enabledPlugins":[]}',
            '{"extraKnownMarketplaces":false}', '{"extraKnownMarketplaces":{"compound-engineering-plugin":[]}}']
        for content in cases:
            with self.subTest(content=content):
                self.settings.write_text(content, encoding="utf-8")
                result = self.chez("apply", "--force", "--exclude=scripts")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.settings.read_text(encoding="utf-8"), content)


if __name__ == "__main__":
    unittest.main()
