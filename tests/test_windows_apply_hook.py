import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt" and shutil.which("chezmoi"), "Windows chezmoi configuration")
class WindowsApplyHookTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        temporary = tempfile.TemporaryDirectory(prefix="windows apply ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.checkout = self.root / "한글 source with spaces"
        self.source = self.checkout / "home"
        self.source.mkdir(parents=True)
        (self.checkout / ".chezmoiroot").write_text("home\n", encoding="utf-8")
        shutil.copy2(self.repo / "home/.chezmoi.toml.tmpl", self.source)
        for name in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(self.repo / "home" / name, self.source / name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.target = self.home / ".apply-proof"
        self.target.write_text("old", encoding="utf-8")
        (self.source / "dot_apply-proof").write_text("new", encoding="utf-8")
        self.config = self.root / "chezmoi.toml"
        self.trace = self.root / "trace.json"
        self.chezmoi = shutil.which("chezmoi")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "HOOK_TRACE": str(self.trace),
        })
        self.config.write_text('[data]\nkeep = "unrelated"\n', encoding="utf-8")

    def run_chezmoi(self, *args, check=True):
        result = subprocess.run([
            self.chezmoi, "--config", str(self.config), "--source", str(self.checkout),
            "--destination", str(self.home), "--no-tty", *args,
        ], env=self.env, capture_output=True, text=True, encoding="utf-8",
            errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def seed_legacy_hook(self, original, current=None):
        generated = {"command": "powershell.exe", "args": ["-File", str(self.root / "removed-gate.ps1")]}
        tables = {
            "data": {"keep": "unrelated"},
            "interpreters.py": {"command": sys.executable, "args": []},
            "hooks.apply.pre": generated if current is None else current,
            "data.dotfilesWindowsApplyPre.original": original,
            "data.dotfilesWindowsApplyPre.generated": generated,
        }
        self.config.write_text("\n".join(
            "[" + table + "]\n" + "\n".join(key + " = " + json.dumps(value) for key, value in values.items())
            for table, values in tables.items()
        ), encoding="utf-8")

    def recording_hook(self, arguments):
        script = self.root / "previous hook.py"
        script.write_text(
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['HOOK_TRACE']).write_text(json.dumps(sys.argv[1:]), encoding='utf-8')\n",
            encoding="utf-8",
        )
        return {"script": str(script), "args": arguments}

    def test_fresh_configuration_applies_without_kubernetes_prerequisites(self):
        self.run_chezmoi("init")
        self.run_chezmoi("apply", "--force")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")

    def test_legacy_gate_without_prior_hook_is_removed_idempotently(self):
        self.seed_legacy_hook({})
        self.run_chezmoi("init")
        self.run_chezmoi("init")
        self.run_chezmoi("apply", "--force")
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")
        config = json.loads(self.run_chezmoi("dump-config", "--format", "json").stdout)
        self.assertEqual(config["data"]["keep"], "unrelated")
        self.assertNotIn("dotfilesWindowsApplyPre", config["data"])

    def test_original_hook_is_restored_and_executes_after_reinitialization(self):
        arguments = ["", 'say "hello"', "C:\\path with spaces\\"]
        self.seed_legacy_hook(self.recording_hook(arguments))
        self.run_chezmoi("init")
        self.run_chezmoi("init")
        self.run_chezmoi("apply", "--force")
        self.assertEqual(json.loads(self.trace.read_text(encoding="utf-8")), arguments)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")

    def test_user_replacement_hook_is_not_overwritten_by_saved_original(self):
        self.seed_legacy_hook({"command": "missing-original-hook"}, self.recording_hook(["user replacement"]))
        self.run_chezmoi("init")
        self.run_chezmoi("apply", "--force")
        self.assertEqual(json.loads(self.trace.read_text(encoding="utf-8")), ["user replacement"])
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")

    def test_restored_hook_failure_still_prevents_application(self):
        self.seed_legacy_hook({"command": sys.executable, "args": ["-c", "raise SystemExit(19)"]})
        self.run_chezmoi("init")
        result = self.run_chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("19", result.stderr)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")


if __name__ == "__main__":
    unittest.main()
