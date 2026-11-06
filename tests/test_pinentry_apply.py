import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


INSTALLERS = ("run_before_20-install-pinentry.ps1.tmpl", "run_before_20-install-pinentry.sh.tmpl")


@unittest.skipUnless(shutil.which("chezmoi") and shutil.which("mise"), "Real chezmoi and mise required")
class PinentryApplyTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="pinentry apply ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.worktree = self.root / "active 한글 worktree's source"
        self.source = self.worktree / "home"
        self.source.mkdir(parents=True)
        (self.worktree / ".chezmoiroot").write_text("home\n", encoding="utf-8")
        shutil.copy2(self.repo / ".chezmoi-bootstrap.toml", self.worktree / ".chezmoi-bootstrap.toml")
        for name in INSTALLERS:
            self.copy_source(".chezmoiscripts/" + name)
            self.copy_source(".chezmoiscripts/" + name, ".chezmoitemplates/" + name)
        for name in ("gpg-settings", "gpg-agent-config"):
            self.copy_source(".chezmoitemplates/" + name)
        self.copy_source(".chezmoidata/gpg.yaml")
        self.copy_source("dot_local/bin/private_dotfiles-pinentry.json.tmpl")
        agent_source = ("AppData/Roaming/gnupg" if os.name == "nt" else "private_dot_gnupg")
        self.copy_source(agent_source + "/modify_gpg-agent.conf")
        self.home = self.root / "destination 한글 user's home"
        self.home.mkdir()
        self.binary = self.home / ".local/bin" / ("dotfiles-pinentry.exe" if os.name == "nt" else "dotfiles-pinentry")
        self.sidecar = self.home / ".local/bin/dotfiles-pinentry.json"
        self.agent = self.home / ("AppData/Roaming/gnupg/gpg-agent.conf" if os.name == "nt" else ".gnupg/gpg-agent.conf")
        self.fallback = str(self.root / "native frontend's 한글" / ("pinentry.exe" if os.name == "nt" else "pinentry"))
        self.receipt = self.root / "tasks.jsonl"
        self.after = self.root / "agent state.json"
        self.config = self.root / "chezmoi.toml"
        self.configure()
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.home / "AppData/Roaming"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "MISE_CONFIG_DIR": str(self.root / "mise config"),
            "MISE_TRUSTED_CONFIG_PATHS": str(self.worktree), "MISE_AUTO_INSTALL": "false",
            "PINENTRY_FIXTURE_ROOT": str(self.root),
        })
        for name in ("MISE_ENV", "MISE_CONFIG_FILE", "PINENTRY_FIXTURE_FAIL"):
            self.env.pop(name, None)
        self.prepare_tasks()

    def copy_source(self, source, destination=None):
        target = self.source / (destination or source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.repo / "home" / source, target)

    def configure(self):
        config = ""
        if os.name == "nt":
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config += ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
                       '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config += "[data]\npinentryProgram = " + json.dumps(self.fallback) + "\n"
        self.config.write_text(config, encoding="utf-8")

    def prepare_tasks(self):
        # These are real mise tasks in a disposable worktree, never native installers.
        tasks = '[hooks]\npostinstall = { task = "bootstrap" }\n'
        for task, action in (("windows-build:visual-studio", "visual-studio"), ("pinentry:build", "build")):
            tasks += '[tasks.' + json.dumps(task) + ']\n'
            if os.name == "nt":
                tasks += 'shell = "powershell -NoProfile -ExecutionPolicy Bypass -Command"\n'
            tasks += 'run = ' + json.dumps("python ./fixture-action.py " + action) + "\n"
        bootstrap = ('chezmoi --config "{{config_root}}/.chezmoi-bootstrap.toml" '
                     '--source "{{config_root}}" --destination "' + str(self.home) + '" '
                     '--cache "' + str(self.root / "chezmoi cache") + '" '
                     '--persistent-state "' + str(self.root / "chezmoi.boltdb") + '" managed --exclude=scripts')
        tasks += '[tasks.bootstrap]\nrun = ' + json.dumps(bootstrap) + "\n"
        (self.worktree / "mise.toml").write_text(tasks, encoding="utf-8")
        # A relative --cd or task run from the caller would select this failing task.
        (self.root / "mise.toml").write_text(
            '[tasks."pinentry:build"]\nrun = "exit 97"\n'
            '[tasks."windows-build:visual-studio"]\nrun = "exit 98"\n', encoding="utf-8")
        (self.worktree / "fixture-action.py").write_text(
            "import json, os\nfrom pathlib import Path\nimport sys\n"
            "root = Path(os.environ['PINENTRY_FIXTURE_ROOT'])\n"
            "action = sys.argv[1]\n"
            "with (root / 'tasks.jsonl').open('a', encoding='utf-8') as stream:\n"
            "    stream.write(json.dumps({'action': action, 'cwd': str(Path.cwd())}) + '\\n')\n"
            "if os.environ.get('PINENTRY_FIXTURE_FAIL') == action:\n"
            "    raise SystemExit('Disposable ' + action + ' failed')\n"
            "if action == 'build':\n"
            "    target = Path('target/release')\n"
            "    target.mkdir(parents=True, exist_ok=True)\n"
            "    (target / ('dotfiles-pinentry.exe' if os.name == 'nt' else 'dotfiles-pinentry')).write_bytes(b'compiled fixture\\n')\n"
            "elif action == 'after':\n"
            "    home = Path(os.environ['HOME'])\n"
            "    binary = home / '.local/bin' / ('dotfiles-pinentry.exe' if os.name == 'nt' else 'dotfiles-pinentry')\n"
            "    assert binary.read_bytes() == b'compiled fixture\\n'\n"
            "    sidecar = home / '.local/bin/dotfiles-pinentry.json'\n"
            "    agent = home / ('AppData/Roaming/gnupg/gpg-agent.conf' if os.name == 'nt' else '.gnupg/gpg-agent.conf')\n"
            "    (root / 'agent state.json').write_text(json.dumps({'fallback': json.loads(sidecar.read_text(encoding='utf-8'))['fallback'], 'agent': agent.read_text(encoding='utf-8')}), encoding='utf-8')\n",
            encoding="utf-8")
        after_name = "run_after_99-completion." + ("ps1" if os.name == "nt" else "sh")
        if os.name == "nt":
            after = ("$ErrorActionPreference = 'Stop'\n& python '" +
                     str(self.worktree / "fixture-action.py").replace("'", "''") +
                     "' after\nexit $LASTEXITCODE\n")
        else:
            after = "#!/bin/sh\nset -eu\npython '" + str(self.worktree / "fixture-action.py").replace("'", "'\\''") + "' after\n"
        (self.source / ".chezmoiscripts" / after_name).write_text(
            after, encoding="utf-8-sig" if os.name == "nt" else "utf-8")

    def chezmoi(self, *args, check=True, config=None):
        result = subprocess.run([
            "chezmoi", "--source", str(self.worktree), "--destination", str(self.home),
            "--config", str(config or self.config), "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "chezmoi.boltdb"), "--no-tty", *args,
        ], cwd=self.root, env=self.env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def actions(self):
        if not self.receipt.exists():
            return []
        return [json.loads(line) for line in self.receipt.read_text(encoding="utf-8").splitlines()]

    def test_platform_rendering_selects_only_native_installer(self):
        for operating_system in ("windows", "darwin", "linux"):
            for installer in INSTALLERS:
                with self.subTest(os=operating_system, installer=installer):
                    context = {"chezmoi": {"os": operating_system, "homeDir": str(self.home), "workingTree": str(self.worktree)},
                               "gpgPlatforms": {operating_system: {"program": "/unused/gpg", "pinentry": self.fallback}}}
                    template = '{{ includeTemplate ' + json.dumps(installer) + ' (' + json.dumps(json.dumps(context, ensure_ascii=False)) + ' | fromJson) }}'
                    script = self.chezmoi("execute-template", template).stdout
                    selected = installer.endswith("ps1.tmpl") == (operating_system == "windows")
                    if not selected:
                        self.assertEqual(script.strip(), "")
                    elif operating_system == "windows":
                        self.assertTrue(script.startswith("\ufeff"))
                        self.assertLess(script.index("windows-build:visual-studio"), script.index("pinentry:build"))
                    else:
                        self.assertTrue(script.startswith("#!/bin/sh\n"))

    def test_explicit_apply_installs_before_completion_and_preserves_unchanged_binary(self):
        self.chezmoi("apply")
        self.assertEqual(self.binary.read_bytes(), b"compiled fixture\n")
        state = json.loads(self.after.read_text(encoding="utf-8"))
        self.assertEqual(state["fallback"], self.fallback)
        self.assertIn("pinentry-program " + str(self.binary).replace("\\", "/"), state["agent"])
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.sidecar.stat().st_mode), 0o600)
            self.assertTrue(os.access(self.binary, os.X_OK))
        expected = ["visual-studio", "build", "after"] if os.name == "nt" else ["build", "after"]
        self.assertEqual([row["action"] for row in self.actions()], expected)
        for row in self.actions():
            if row["action"] != "after":
                self.assertEqual(Path(row["cwd"]), self.worktree)
        # Set an old timestamp so an unnecessary copy cannot hide in clock resolution.
        os.utime(self.binary, (946684800, 946684800))
        before = self.binary.stat().st_mtime_ns
        if os.name != "nt":
            self.binary.chmod(0o644)
        self.chezmoi("apply")
        self.assertEqual(self.binary.stat().st_mtime_ns, before)
        if os.name != "nt":
            self.assertTrue(os.access(self.binary, os.X_OK))
        self.assertEqual([row["action"] for row in self.actions()], expected * 2)
        self.assertEqual(json.loads(self.after.read_text(encoding="utf-8")), state)

    def test_build_failure_preserves_prior_binary_configuration_and_agent_state(self):
        self.chezmoi("apply")
        prior = {path: path.read_bytes() for path in (self.binary, self.sidecar, self.agent, self.after)}
        self.fallback += " changed"
        self.configure()
        self.env["PINENTRY_FIXTURE_FAIL"] = "build"
        result = self.chezmoi("apply", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Disposable build failed", result.stdout + result.stderr)
        for path, content in prior.items():
            self.assertEqual(path.read_bytes(), content, str(path))
        self.assertEqual(sum(row["action"] == "after" for row in self.actions()), 1)

    def test_bootstrap_managed_dry_run_and_script_exclusion_do_not_install(self):
        bootstrap = subprocess.run(["mise", "--cd", str(self.worktree), "install"],
                                   cwd=self.root, env=self.env, capture_output=True, text=True,
                                   encoding="utf-8", errors="backslashreplace", timeout=60)
        self.assertEqual(bootstrap.returncode, 0, bootstrap.stdout + bootstrap.stderr)
        self.assertIn("dotfiles-pinentry.json", bootstrap.stdout + bootstrap.stderr)
        self.chezmoi("managed")
        self.chezmoi("apply", "--dry-run")
        self.chezmoi("managed", "--exclude=scripts", config=self.repo / ".chezmoi-bootstrap.toml")
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertFalse(self.receipt.exists())
        self.chezmoi("apply", "--exclude=scripts")
        self.assertFalse(self.binary.exists())
        self.assertFalse(self.receipt.exists())
        self.assertFalse(self.after.exists())

    @unittest.skipUnless(os.name == "nt", "Windows Visual Studio prerequisite")
    def test_visual_studio_failure_prevents_build_and_configuration(self):
        self.env["PINENTRY_FIXTURE_FAIL"] = "visual-studio"
        result = self.chezmoi("apply", check=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Disposable visual-studio failed", result.stdout + result.stderr)
        self.assertEqual([row["action"] for row in self.actions()], ["visual-studio"])
        for path in (self.binary, self.sidecar, self.agent, self.after):
            self.assertFalse(path.exists(), str(path))


if __name__ == "__main__":
    unittest.main()
