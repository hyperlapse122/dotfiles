import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt" and shutil.which("chezmoi"), "Windows chezmoi apply hooks")
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
        scripts = self.checkout / "scripts"
        scripts.mkdir()
        shutil.copy2(self.repo / "scripts/windows-apply-pre.ps1", scripts)
        # The OS probe is covered separately; this fixture tests real chezmoi dispatch.
        (scripts / "check-wsl2.ps1").write_text(
            "Add-Content -LiteralPath $env:HOOK_TRACE -Value 'gate'\n"
            "if ($env:HOOK_BLOCK -eq '1') { throw 'WSL2 fixture is not ready' }\n",
            encoding="utf-8",
        )
        self.home = self.root / "home"
        self.home.mkdir()
        self.target = self.home / ".apply-proof"
        self.target.write_text("old", encoding="utf-8")
        (self.source / "dot_apply-proof").write_text("new", encoding="utf-8")
        self.script_marker = self.root / "applied.txt"
        actions = self.source / ".chezmoiscripts"
        actions.mkdir()
        (actions / "run_after-proof.ps1").write_text(
            "Set-Content -LiteralPath $env:APPLY_MARKER -Value 'applied'\n", encoding="utf-8"
        )
        self.config = self.root / "chezmoi.toml"
        self.trace = self.root / "trace.txt"
        self.outside = self.root / "unrelated directory"
        self.outside.mkdir()
        self.chezmoi = shutil.which("chezmoi")
        self.shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "HOOK_TRACE": str(self.trace), "APPLY_MARKER": str(self.script_marker),
        })
        self.env.pop("HOOK_BLOCK", None)
        self.config.write_text('[data]\nkeep = "unrelated"\n', encoding="utf-8")

    def run_chezmoi(self, *args, check=True):
        result = subprocess.run([
            self.chezmoi, "--config", str(self.config), "--source", str(self.checkout),
            "--destination", str(self.home), "--no-tty", *args,
        ], cwd=self.outside, env=self.env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def init(self):
        return self.run_chezmoi("init")

    def lines(self):
        return self.trace.read_text(encoding="utf-8-sig").splitlines() if self.trace.exists() else []

    def test_failed_gate_blocks_files_and_apply_scripts(self):
        self.env["HOOK_BLOCK"] = "1"
        self.init()
        self.assertFalse(self.trace.exists(), "Initialization ran the apply gate")
        result = self.run_chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WSL2", result.stderr)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")
        self.assertFalse(self.script_marker.exists())

    def test_dry_run_checks_prerequisites_without_applying(self):
        self.init()
        self.run_chezmoi("apply", "--dry-run")
        self.assertEqual(self.lines(), ["gate"])
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")
        self.assertFalse(self.script_marker.exists())
        self.env["HOOK_BLOCK"] = "1"
        result = self.run_chezmoi("apply", "--dry-run", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")

    def test_script_hook_survives_reinitialization_and_unchanged_apply(self):
        previous = self.root / "prior hook.py"
        previous.write_text(
            "import os, pathlib, sys\n"
            "with pathlib.Path(os.environ['HOOK_TRACE']).open('a', encoding='utf-8') as stream:\n"
            "    stream.write('previous:' + sys.argv[1] + '\\n')\n",
            encoding="utf-8",
        )
        self.config.write_text(
            '[data]\nkeep = "unrelated"\n'
            '[interpreters.py]\ncommand = ' + json.dumps(sys.executable) + '\nargs = []\n'
            '[hooks.apply.pre]\nscript = ' + json.dumps(str(previous)) +
            '\nargs = ["argument with spaces"]\n', encoding="utf-8"
        )
        self.init()
        self.run_chezmoi("apply", "--force")
        self.init()
        self.run_chezmoi("apply", "--force")
        self.assertEqual(self.lines(), ["gate", "previous:argument with spaces"] * 2)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "new")
        data = json.loads(self.run_chezmoi("dump-config", "--format", "json").stdout)
        self.assertEqual(data["data"]["keep"], "unrelated")
        self.env["HOOK_BLOCK"] = "1"
        result = self.run_chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.lines()[-1], "gate")
        self.assertEqual(self.lines().count("previous:argument with spaces"), 2)

    def test_previous_command_failure_prevents_application(self):
        previous = self.root / "previous.ps1"
        previous.write_text("exit 19\n", encoding="utf-8")
        self.config.write_text(
            '[hooks.apply.pre]\ncommand = ' + json.dumps(self.shell) +
            '\nargs = ["-NoProfile", "-File", ' + json.dumps(str(previous)) + ']\n',
            encoding="utf-8",
        )
        self.init()
        result = self.run_chezmoi("apply", "--force", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "old")
        self.assertFalse(self.script_marker.exists())


if __name__ == "__main__":
    unittest.main()
