import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows global chezmoi configuration")
class GlobalChezmoiTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        self.scratch = tempfile.TemporaryDirectory(prefix="global chezmoi ")
        self.addCleanup(self.scratch.cleanup)
        # Native tools must share one spelling instead of mixing 8.3 and long paths.
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "user home"
        self.home.mkdir()
        self.config_root = self.root / "config"
        self.config = self.config_root / "chezmoi" / "chezmoi.toml"
        self.config.parent.mkdir(parents=True)
        self.checkout = self.root / "한글 checkout with spaces"
        self.checkout.mkdir()
        self.remote = self.root / "remote.git"
        self.publisher = self.root / "publisher"
        self.outside = self.root / "unrelated directory"
        self.outside.mkdir()
        # A fixture-local copy exercises native executable discovery without
        # installing packages or editing the owner's PATH/registry.
        native_dir = self.root / "native tools"
        native_dir.mkdir()
        self.chezmoi = native_dir / "chezmoi.exe"
        shutil.copy2(shutil.which("chezmoi"), self.chezmoi)
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(native_dir) + os.pathsep + self.env["PATH"],
            "USERPROFILE": str(self.home), "HOME": str(self.home),
            "APPDATA": str(self.config_root), "XDG_CONFIG_HOME": str(self.config_root),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        })
        self.git("init", "--bare", str(self.remote))
        self.git("clone", str(self.remote), str(self.publisher))
        for name in (".chezmoiroot", ".chezmoi-bootstrap.toml", "configure-chezmoi.ps1"):
            shutil.copy2(self.repo / name, self.publisher / name)
        hook_scripts = self.publisher / "scripts"
        hook_scripts.mkdir()
        shutil.copy2(self.repo / "scripts/windows-apply-pre.ps1", hook_scripts)
        # Registration tests isolate source selection from host WSL prerequisites.
        (hook_scripts / "check-wsl2.ps1").write_text("# Ready fixture\n", encoding="utf-8")
        (self.publisher / "home").mkdir()
        for name in (".chezmoi.toml.tmpl", ".chezmoiignore"):
            shutil.copy2(self.repo / "home" / name, self.publisher / "home" / name)
        for name in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(self.repo / "home" / name, self.publisher / "home" / name)
        (self.publisher / "home" / "dot_global-proof").write_text("first", encoding="utf-8")
        self.publish("initial")
        self.git("clone", str(self.remote), str(self.checkout))
        self.git("-C", str(self.checkout), "remote", "set-url", "origin",
                 "https://github.com/hyperlapse122/dotfiles.git")
        self.git("config", "--global", "url." + str(self.remote).replace("\\", "/") + ".insteadOf",
                 "https://github.com/hyperlapse122/dotfiles.git")

    def git(self, *args):
        return subprocess.run(["git", *args], env=self.env, check=True,
                              capture_output=True, text=True, encoding="utf-8", timeout=30)

    def publish(self, message):
        self.git("-C", str(self.publisher), "add", ".")
        self.git("-C", str(self.publisher), "commit", "-m", message)
        self.git("-C", str(self.publisher), "push", "origin", "HEAD")

    def register(self, source=None):
        arguments = ["-Source", str(source)] if source is not None else []
        return subprocess.run(
            [str(self.shell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.checkout / "configure-chezmoi.ps1"), *arguments],
            cwd=self.outside, env=self.env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )

    def run_chezmoi(self, *args):
        return subprocess.run([str(self.chezmoi), *args], cwd=self.outside, env=self.env,
                              capture_output=True, text=True, encoding="utf-8", timeout=60)

    def test_file_invocation_defaults_to_its_own_checkout(self):
        script = self.checkout / "configure-chezmoi.ps1"
        shutil.copy2(self.repo / script.name, script)
        shutil.copy2(self.repo / ".chezmoi-bootstrap.toml", self.checkout)
        result = subprocess.run(
            [str(self.shell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
            cwd=self.outside, env=self.env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("execute-template", "{{ .chezmoi.workingTree }}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, self.checkout.as_posix())
        self.assertFalse((self.home / ".global-proof").exists())

    def test_registration_and_updates_keep_permanent_checkout(self):
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        target = self.home / ".global-proof"
        self.assertFalse(target.exists(), "Registration applied managed files")
        (self.publisher / "home" / "dot_global-proof").write_text("pulled change", encoding="utf-8")
        self.publish("change managed setting")
        result = self.run_chezmoi("update", "--apply=false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(target.exists())
        result = self.run_chezmoi("apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "pulled change")
        template = self.publisher / "home" / ".chezmoi.toml.tmpl"
        with template.open("a", encoding="utf-8") as stream:
            stream.write('\n[data.fixture]\nupdateProof = "regenerated"\n')
        (self.publisher / "home" / "dot_global-proof").unlink()
        (self.publisher / "home" / "dot_global-proof.tmpl").write_text("{{ .fixture.updateProof }}", encoding="utf-8")
        self.publish("change configuration template")
        result = self.run_chezmoi("update", "--apply=false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("init")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "regenerated")
        result = self.run_chezmoi("execute-template", '{{ .fixture.updateProof }}|{{ .chezmoi.workingTree }}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "regenerated|" + str(self.checkout).replace("\\", "/"))
        (self.publisher / "home" / "dot_global-proof.tmpl").write_text("still connected", encoding="utf-8")
        self.publish("change after init")
        result = self.run_chezmoi("update", "--apply=false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("apply")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "still connected")

    def test_repeat_preserves_unrelated_configuration(self):
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with self.config.open("a", encoding="utf-8") as stream:
            stream.write('\n[data.fixture]\nkeep = "existing setting"\n')
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("execute-template", '{{ .fixture.keep }}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "existing setting")
        self.assertFalse((self.home / ".global-proof").exists())

    def test_init_only_pwsh_does_not_block_application_outside_mise(self):
        init_only = self.chezmoi.parent / "pwsh.cmd"
        init_only.write_text("@echo off\nexit /b 17\n", encoding="ascii")
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        init_only.unlink()
        windows = Path(os.environ["SystemRoot"])
        self.env["PATH"] = os.pathsep.join((
            str(self.chezmoi.parent),
            str(windows / "System32/WindowsPowerShell/v1.0"),
            str(windows / "System32"),
            str(Path(shutil.which("git")).resolve().parent),
        ))
        self.assertIsNone(shutil.which("pwsh", path=self.env["PATH"]))
        scripts = self.checkout / "home/.chezmoiscripts"
        scripts.mkdir()
        (scripts / "run_before_10-interpreter-proof.ps1").write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "[IO.File]::WriteAllText((Join-Path $env:USERPROFILE 'interpreter-proof.txt'), 'ran without mise')\n",
            encoding="ascii",
        )
        result = self.run_chezmoi("apply", "--force")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.home / "interpreter-proof.txt").read_text(encoding="utf-8"), "ran without mise")

    def test_other_source_and_format_are_not_overwritten(self):
        for filename, content in (
            ("chezmoi.toml", 'sourceDir = "C:/other-dotfiles"\n'),
            ("chezmoi.yaml", 'sourceDir: "C:/other-dotfiles"\n'),
        ):
            with self.subTest(filename=filename):
                config = self.config.parent / filename
                config.write_text(content, encoding="utf-8")
                result = self.register()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(config.read_text(encoding="utf-8"), content)
                self.assertFalse((self.home / ".global-proof").exists())
                config.unlink()

    def test_linked_worktree_is_not_registered(self):
        linked = self.root / "temporary linked worktree"
        self.git("-C", str(self.checkout), "worktree", "add", "-b", "test-linked", str(linked))
        result = self.register(linked)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.config.exists())
        self.assertFalse((self.home / ".global-proof").exists())

    def test_native_init_failure_does_not_report_registration(self):
        self.chezmoi.unlink()
        self.chezmoi.with_suffix(".cmd").write_text("@echo off\nexit /b 17\n", encoding="ascii")
        result = self.register()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.config.exists())
        self.assertFalse((self.home / ".global-proof").exists())

    def test_additional_xdg_configuration_is_not_shadowed(self):
        inherited = self.root / "system config" / "chezmoi" / "chezmoi.toml"
        inherited.parent.mkdir(parents=True)
        original = 'sourceDir = "C:/other-dotfiles"\n'
        inherited.write_text(original, encoding="utf-8")
        result = self.register()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(inherited.read_text(encoding="utf-8"), original)
        self.assertFalse(self.config.exists())

    def test_home_shorthand_preserves_same_source_configuration(self):
        source = self.home / "src" / "github.com" / "hyperlapse122" / "dotfiles"
        source.parent.mkdir(parents=True)
        self.checkout.rename(source)
        self.checkout = source
        self.config.write_text(
            'sourceDir = "~/src/github.com/hyperlapse122/dotfiles"\nworkingTree = "~/src/github.com/hyperlapse122/dotfiles"\n[data]\nkeep = "preserved"\n',
            encoding="utf-8",
        )
        result = self.register()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_chezmoi("execute-template", "{{ .keep }}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "preserved")

    def test_relocated_mise_is_skipped_before_native_executable(self):
        original_path = self.env["PATH"]
        cases = (
            ("MISE_DATA_DIR", self.root / "relocated mise", "installs/chezmoi/1"),
            ("MISE_SHIMS_DIR", self.root / "custom shims", ""),
            ("XDG_DATA_HOME", self.root / "xdg relocated", "mise/installs/chezmoi/1"),
            ("MISE_INSTALL_STORE_DIR", self.root / "custom store", "chezmoi"),
        )
        for key, root, suffix in cases:
            with self.subTest(key=key):
                directory = root / suffix
                directory.mkdir(parents=True)
                (directory / "chezmoi.cmd").write_text("@echo off\nexit /b 17\n", encoding="ascii")
                previous = self.env.get(key)
                self.env[key] = root.as_posix()
                self.env["PATH"] = str(directory) + os.pathsep + original_path
                result = self.register()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if previous is None:
                    del self.env[key]
                else:
                    self.env[key] = previous
        self.assertFalse((self.home / ".global-proof").exists())


if __name__ == "__main__":
    unittest.main()
