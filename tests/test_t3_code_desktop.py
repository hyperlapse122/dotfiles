import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest


@unittest.skipUnless(shutil.which("chezmoi"), "Chezmoi required")
class T3CodeDesktopTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="t3 desktop ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copytree(self.repo / "home/.chezmoitemplates", self.source / ".chezmoitemplates")
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.release = {"tag_name": "v9.8.7", "assets": [
            {"name": f"T3-Code-9.8.7-{arch}.deb",
             "browser_download_url": f"https://example.invalid/desktop-{arch}.deb",
             "digest": "sha256:" + digest * 64}
            for arch, digest in (("amd64", "a"), ("arm64", "b"))
        ]}

    def render(self, relative, os_name, arch, release=None):
        context = {"chezmoi": {"os": os_name, "arch": arch,
                              "osRelease": {"id": "ubuntu"},
                              "destDir": self.home.as_posix(), "workingTree": self.repo.as_posix()},
                   "t3CodeRelease": self.release if release is None else release}
        template = (self.repo / "home" / relative).read_text(encoding="utf-8")
        wrapper = ('{{ template "subject" (' + json.dumps(json.dumps(context)) + ' | fromJson) }}'
                   '{{ define "subject" }}' + template + '{{ end }}')
        return subprocess.run([
            shutil.which("chezmoi"), "--source", str(self.source),
            "--destination", str(self.home), "--config", str(self.config),
            "--cache", str(self.root / "chezmoi cache"),
            "--persistent-state", str(self.root / "state.boltdb"),
            "execute-template",
        ], input=wrapper, env=self.env, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60)

    def test_ubuntu_selects_architecture_and_enforces_release_integrity(self):
        for arch, digest in (("amd64", "a"), ("arm64", "b")):
            with self.subTest(arch=arch):
                result = self.render(".chezmoiexternals/t3-code.toml.tmpl", "linux", arch)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                staged = tomllib.loads(result.stdout)
                self.assertEqual(len(staged), 1)
                entry = next(iter(staged.values()))
                self.assertEqual(entry["type"], "file")
                self.assertFalse(entry.get("executable", False))
                self.assertEqual(entry["url"],
                                 f"https://example.invalid/desktop-{arch}.deb#sha256=" + digest * 64)
                self.assertEqual(entry["checksum"]["sha256"], digest * 64)
        release = json.loads(json.dumps(self.release))
        del release["assets"][0]["digest"]
        result = self.render(".chezmoiexternals/t3-code.toml.tmpl", "linux", "amd64", release)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stdout + result.stderr)

    def test_other_platforms_do_not_stage_a_debian_payload(self):
        for os_name, arch in (("windows", "amd64"), ("windows", "arm64"),
                              ("darwin", "arm64"), ("darwin", "amd64"), ("linux", "386")):
            with self.subTest(os=os_name, arch=arch):
                result = self.render(".chezmoiexternals/t3-code.toml.tmpl", os_name, arch,
                                     {"invalid": "must not be examined"})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(tomllib.loads(result.stdout), {})

    @unittest.skipIf(os.name == "nt", "Native POSIX application bundle retention")
    def test_manual_user_macos_bundle_is_retained_without_homebrew(self):
        app = self.home / "Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)"
        app.parent.mkdir(parents=True)
        app.write_text("#!/bin/sh\nexit 91\n", encoding="utf-8")
        app.chmod(0o755)
        before = app.read_bytes()
        result = self.render(".chezmoiscripts/run_onchange_after_30-install-t3-code.sh.tmpl",
                             "darwin", "arm64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        script = self.root / "install.sh"
        script.write_text(result.stdout, encoding="utf-8")
        # No commands are available; retaining the bundle must not require brew or launch the GUI.
        env = dict(self.env, PATH=str(self.root / "empty path"))
        applied = subprocess.run(["/bin/sh", str(script)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertEqual(app.read_bytes(), before)

    @unittest.skipUnless(os.name == "nt", "Native Windows missing desktop launcher")
    def test_missing_desktop_fails_without_using_another_t3(self):
        result = self.render("dot_local/bin/t3.cmd.tmpl", "windows", "amd64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        launcher = self.home / ".local/bin/t3.cmd"
        launcher.parent.mkdir(parents=True)
        launcher.write_text(result.stdout, encoding="utf-8")
        commands = self.root / "commands"
        commands.mkdir()
        (commands / "t3.cmd").write_text("@exit /b 39\n", encoding="utf-8")
        env = dict(self.env, PATH=str(commands), ProgramFiles=str(self.root / "program files"),
                   **{"ProgramFiles(x86)": str(self.root / "program files x86"),
                      "ProgramW6432": str(self.root / "native program files")})
        applied = subprocess.run([os.environ["COMSPEC"], "/d", "/c", str(launcher)],
                                 env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(applied.returncode, 127, applied.stdout + applied.stderr)
        self.assertIn("chezmoi apply", applied.stderr)


if __name__ == "__main__":
    unittest.main()
