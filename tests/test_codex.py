import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


REPO = Path(__file__).resolve().parents[1]
PLUGIN_ID = "compound-engineering@compound-engineering-plugin"


class CodexTest(unittest.TestCase):
    def setUp(self):
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running Codex tests")
        self.scratch = tempfile.TemporaryDirectory(prefix="codex ' 한글 ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home, self.source = self.root / "home", self.root / "source"
        self.home.mkdir()
        self.source.mkdir()
        for name in (".chezmoidata", ".chezmoitemplates", "private_dot_codex"):
            shutil.copytree(REPO / "home" / name, self.source / name)
        shutil.copy2(REPO / "home/.chezmoiignore", self.source / ".chezmoiignore")
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "CODEX_HOME": str(self.root / "foreign-codex"),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system-config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"), "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.codex = self.home / ".codex"
        self.settings = self.codex / "config.toml"

    def chez(self, *args, input=None):
        return subprocess.run([
            self.chezmoi, "--config", str(self.config), "--source", str(self.source),
            "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
            "--persistent-state", str(self.root / "chezmoi-state"), *args,
        ], env=self.env, input=input, text=True, capture_output=True,
            encoding="utf-8", errors="backslashreplace", timeout=60)

    def apply(self):
        result = self.chez("apply", "--force", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_initial_apply_private_config_and_instructions(self):
        self.config.write_text("umask = 0o022\n", encoding="utf-8")
        (self.source / ".chezmoitemplates/agent-instructions").write_text(
            'common-marker\n{{ if eq .harness "codex" }}codex-marker{{ end }}\n'
            '{{ if eq .harness "omp" }}foreign-marker{{ end }}\n', encoding="utf-8")
        self.apply()
        settings = tomllib.loads(self.settings.read_text(encoding="utf-8"))
        self.assertIs(settings["check_for_update_on_startup"], False)
        self.assertIs(settings["plugins"][PLUGIN_ID]["enabled"], True)
        marketplace = settings["marketplaces"]["compound-engineering-plugin"]
        self.assertEqual(marketplace["source_type"], "local")
        self.assertEqual(Path(marketplace["source"]), self.home / ".local/share/dotfiles/harness-plugins/compound-engineering")
        instructions = (self.codex / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("common-marker", instructions)
        self.assertIn("codex-marker", instructions)
        self.assertNotIn("foreign-marker", instructions)
        self.assertFalse(Path(self.env["CODEX_HOME"]).exists())
        result = self.chez("dump", "--format=json", "--parent-dirs", str(self.settings), str(self.codex / "AGENTS.md"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(result.stdout)
        for path, mode in ((".codex", 0o700), (".codex/config.toml", 0o600), (".codex/AGENTS.md", 0o600)):
            self.assertEqual(state[path]["perm"], mode)
            if os.name != "nt":
                self.assertEqual((self.home / path).stat().st_mode & 0o777, mode)

    def test_reapply_reconciles_only_owned_settings(self):
        self.codex.mkdir()
        auth = self.codex / "auth.json"
        override = self.codex / "AGENTS.override.md"
        auth.write_bytes(b'{"fixture": "not-a-credential"}')
        override.write_bytes(b"native override stays owned by user\n")
        original = '''check_for_update_on_startup = true
model = "user-model"
[history]
max_bytes = 12345
[plugins."unrelated@local"]
enabled = false
[plugins."compound-engineering@compound-engineering-plugin"]
enabled = false
[plugins."compound-engineering@compound-engineering-plugin".mcp_servers.example]
enabled = false
[marketplaces.unrelated]
source_type = "local"
source = "/keep"
[marketplaces.compound-engineering-plugin]
source_type = "git"
source = "https://example.invalid/latest"
ref = "main"
sparse_paths = ["old"]
'''
        for _ in range(2):
            self.settings.write_text(original, encoding="utf-8")
            self.apply()
            parsed = tomllib.loads(self.settings.read_text(encoding="utf-8"))
            self.assertIs(parsed["check_for_update_on_startup"], False)
            self.assertEqual(parsed["model"], "user-model")
            self.assertEqual(parsed["history"], {"max_bytes": 12345})
            self.assertEqual(parsed["plugins"]["unrelated@local"], {"enabled": False})
            self.assertEqual(parsed["plugins"][PLUGIN_ID], {"enabled": True, "mcp_servers": {"example": {"enabled": False}}})
            self.assertEqual(parsed["marketplaces"]["unrelated"], {"source_type": "local", "source": "/keep"})
            self.assertNotIn("ref", parsed["marketplaces"]["compound-engineering-plugin"])
            self.assertNotIn("sparse_paths", parsed["marketplaces"]["compound-engineering-plugin"])
            self.assertEqual(auth.read_bytes(), b'{"fixture": "not-a-credential"}')
            self.assertEqual(override.read_bytes(), b"native override stays owned by user\n")
        before = self.settings.read_bytes()
        self.apply()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_invalid_toml_and_owned_table_shapes_fail_without_replacement(self):
        self.codex.mkdir()
        for text in ('model = [unterminated\n', 'plugins = []\n', 'marketplaces = false\n',
                     '[plugins]\n"' + PLUGIN_ID + '" = false\n',
                     '[marketplaces]\ncompound-engineering-plugin = "invalid"\n'):
            with self.subTest(text=text):
                self.settings.write_text(text, encoding="utf-8")
                result = self.chez("apply", "--force", "--exclude=scripts")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.settings.read_text(encoding="utf-8"), text)



if __name__ == "__main__":
    unittest.main()
