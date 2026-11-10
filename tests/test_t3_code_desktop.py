import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from unittest import mock

from smoke_t3_code import server_process


class NativeT3SmokeDiscoveryTest(unittest.TestCase):
    def test_native_consumers_reach_missing_desktop_guard_without_antigravity_helpers(self):
        import importlib

        cases = [('smoke_pi', 't3_startup'), ('smoke_grok', 't3_startup')]
        if Path(__file__).with_name('smoke_t3_instructions.py').is_file():
            cases.append(('smoke_t3_instructions', 't3_turns'))
        for name, entrypoint in cases:
            smoke = importlib.import_module(name)
            with self.subTest(smoke=name), mock.patch.object(Path, 'is_file', return_value=False):
                with self.assertRaisesRegex(RuntimeError, 'Install the T3 Code desktop application'):
                    if entrypoint == 't3_turns':
                        smoke.t3_turns(None, None, None, {}, 'fixture', False, [], '', ('codex', 'claude', 'pi'))
                    elif name == 'smoke_grok':
                        smoke.t3_startup(None, None, None, None, {}, 'fixture', False, [])
                    else:
                        smoke.t3_startup(None, None, None, None, {}, 'fixture', False)


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
        (self.source / "private_dot_t3").mkdir()
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
        self.host_report = {"supported": True, "blockers": []}
        probe_template = self.source / ".chezmoitemplates/t3-code-desktop"
        native_probe = ('output "mise" "--cd" .chezmoi.workingTree "exec" "python" "--" "python" '
                        '(joinPath .chezmoi.workingTree "scripts" "linux-apps.py") "--inspect" | fromJson')
        self.assertIn(native_probe, probe_template.read_text())
        probe_template.write_text(probe_template.read_text().replace(native_probe, 'get . "fixtureHostReport"'))
        self.release = {"tag_name": "v9.8.7", "assets": [
            {"name": f"T3-Code-9.8.7-{arch}.deb",
             "browser_download_url": f"https://example.invalid/desktop-{arch}.deb",
             "digest": "sha256:" + digest * 64}
            for arch, digest in (("amd64", "a"), ("arm64", "b"))
        ]}

    def test_reduced_source_without_host_probe_fails_closed(self):
        template = self.repo / 'home/.chezmoitemplates/t3-code-desktop'
        (self.source / '.chezmoitemplates/t3-code-desktop').write_text(template.read_text())
        result = self.render('.chezmoitemplates/t3-code-desktop', 'linux', 'amd64', working_tree=self.source)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)['supported'])

    def render(self, relative, os_name, arch, release=None, working_tree=None):
        context = {"chezmoi": {"os": os_name, "arch": arch,
                              "osRelease": {"id": "ubuntu", "versionID": "26.04"},
                              "destDir": self.home.as_posix(), "sourceDir": self.source.as_posix(), "workingTree": (working_tree or self.repo).as_posix()},
                   "fixtureHostReport": self.host_report,
                   "t3CodeRelease": self.release if release is None else release}
        template = (self.repo / "home" / relative).read_text(encoding="utf-8")
        if relative == ".chezmoitemplates/external-assets/t3-code.toml.tmpl":
            for native, isolated in (
                ("/opt/T3 Code (Beta)/t3code", self.root / "installed-desktop"),
                ("/var/lib/dpkg/status", self.root / "dpkg-status"),
            ):
                template = template.replace(native, isolated.as_posix())
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
        for arch, digest in (("amd64", "a"),):
            with self.subTest(arch=arch):
                result = self.render(".chezmoitemplates/external-assets/t3-code.toml.tmpl", "linux", arch)
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
        result = self.render(".chezmoitemplates/external-assets/t3-code.toml.tmpl", "linux", "amd64", release)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stdout + result.stderr)

    def test_unsupported_linux_host_does_not_stage_or_install_t3(self):
        self.host_report = {"supported": False, "blockers": ["Ubuntu Desktop required"]}
        for subject in (".chezmoitemplates/external-assets/t3-code.toml.tmpl",
                        ".chezmoiscripts/run_onchange_after_30-install-t3-code.sh.tmpl"):
            rendered = self.render(subject, "linux", "amd64", {"invalid": "must not be examined"})
            self.assertEqual(rendered.returncode, 0, rendered.stdout + rendered.stderr)
            self.assertEqual(rendered.stdout.strip(), "")

    def test_ignore_gate_tracks_workstation_host_eligibility(self):
        for supported in (True, False):
            self.host_report = {"supported": supported, "blockers": []}
            result = self.render(".chezmoiignore", "linux", "amd64")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            ignored = result.stdout.splitlines()
            self.assertEqual(".t3" in ignored, not supported)
            self.assertEqual(".local/bin/t3" in ignored, not supported)

    def test_installed_ubuntu_package_skips_release_lookup_and_download(self):
        (self.root / "dpkg-status").write_bytes(
            b"Package: t3code\nStatus: install ok installed\n\n")
        result = self.render(".chezmoitemplates/external-assets/t3-code.toml.tmpl", "linux", "amd64",
                             {"invalid": "must not be examined"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(tomllib.loads(result.stdout), {})

    def test_other_platforms_do_not_stage_a_debian_payload(self):
        for os_name, arch in (("windows", "amd64"), ("windows", "arm64"),
                              ("darwin", "arm64"), ("darwin", "amd64"), ("linux", "386"), ("linux", "arm64")):
            with self.subTest(os=os_name, arch=arch):
                result = self.render(".chezmoitemplates/external-assets/t3-code.toml.tmpl", os_name, arch,
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
    def test_launcher_waits_for_gui_cli_and_preserves_arguments_and_exit_code(self):
        compiler = Path(os.environ["SystemRoot"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        if not compiler.is_file():
            self.skipTest(".NET Framework C# compiler required for native GUI fixture")
        app = Path(self.env["LOCALAPPDATA"]) / "Programs/t3code/T3 Code (Beta).exe"
        app.parent.mkdir(parents=True)
        source = self.root / "GuiCli.cs"
        source.write_text(
            'class GuiCli { static int Main(string[] args) { '
            'System.Threading.Thread.Sleep(1000); '
            'System.IO.File.WriteAllLines(args[1], args); return 37; } }', encoding="utf-8")
        compiled = subprocess.run([str(compiler), "/nologo", "/target:winexe", "/out:" + str(app),
                                   str(source)], capture_output=True, text=True, timeout=30)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        rendered = self.render("dot_local/bin/t3.ps1.tmpl", "windows", "amd64")
        self.assertEqual(rendered.returncode, 0, rendered.stdout + rendered.stderr)
        launcher = self.home / ".local/bin/t3.ps1"
        launcher.parent.mkdir(parents=True)
        launcher.write_text(rendered.stdout, encoding="utf-8")
        marker = self.root / "GUI CLI arguments.txt"
        shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        command = "& '" + str(launcher).replace("'", "''") + "' '" + str(marker).replace("'", "''")
        command += "' 'space value' 'quote\"value' 'trailing\\'; exit $LASTEXITCODE"
        applied = subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
                                 env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(applied.returncode, 37, applied.stdout + applied.stderr)
        arguments = marker.read_text(encoding="utf-8-sig").splitlines()
        self.assertEqual(arguments[1:], [str(marker), "space value", 'quote"value', "trailing\\"])

    @unittest.skipIf(os.name == "nt", "POSIX Homebrew installation")
    def test_macos_install_accepts_confirmation_without_input(self):
        result = self.render(".chezmoiscripts/run_onchange_after_30-install-t3-code.sh.tmpl",
                             "darwin", "arm64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        brew = self.root / "brew"
        brew.write_text('#!/bin/sh\ncase "$1" in\n'
                        'list) exit 1 ;;\n'
                        'install) [ "$*" = "install --yes --cask t3-code" ] ;;\n'
                        '*) exit 92 ;;\nesac\n', encoding="utf-8")
        brew.chmod(0o755)
        script = self.root / "install.sh"
        script.write_text(result.stdout.replace("/opt/homebrew/bin/brew", shlex.quote(brew.as_posix()))
                          .replace("/Applications/T3 Code (Beta).app", "/missing-t3-test.app"),
                          encoding="utf-8")
        applied = subprocess.run(["/bin/sh", str(script)], env=self.env,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)

    @unittest.skipUnless(os.name == "nt", "Native Windows missing desktop launcher")
    def test_missing_desktop_fails_without_using_another_t3(self):
        result = self.render("dot_local/bin/t3.ps1.tmpl", "windows", "amd64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        launcher = self.home / ".local/bin/t3.ps1"
        launcher.parent.mkdir(parents=True)
        launcher.write_text(result.stdout, encoding="utf-8")
        commands = self.root / "commands"
        commands.mkdir()
        (commands / "t3.ps1").write_text("exit 39\n", encoding="utf-8")
        env = dict(self.env, PATH=str(commands), ProgramFiles=str(self.root / "program files"),
                   **{"ProgramFiles(x86)": str(self.root / "program files x86"),
                      "ProgramW6432": str(self.root / "native program files")})
        shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        applied = subprocess.run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(launcher)],
                                 env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(applied.returncode, 127, applied.stdout + applied.stderr)
        self.assertIn("chezmoi apply", applied.stderr)


@unittest.skipUnless(os.name == "nt", "Windows descendant lifetime and directory locks")
class T3ServerLifetimeTest(unittest.TestCase):
    def test_descendant_releases_working_directory_after_launcher_exits(self):
        with tempfile.TemporaryDirectory(prefix="t3 process lifetime ") as scratch:
            directory = Path(scratch) / "working directory"
            directory.mkdir()
            marker = directory / "ready"
            child = ("from pathlib import Path; import time; "
                     "Path('ready').write_text('ready'); time.sleep(120)")
            parent = ("import subprocess, sys; sys.stdin.read(1); "
                      "p = subprocess.Popen([sys.executable, '-c', sys.argv[1]], "
                      "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(p.pid, flush=True)")
            child_pid = None
            try:
                with server_process([sys.executable, "-c", parent, child], cwd=directory,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True) as process:
                    process.stdin.write("x")
                    process.stdin.close()
                    child_pid = int(process.stdout.readline())
                    process.wait(timeout=10)
                    deadline = time.monotonic() + 10
                    while not marker.exists():
                        if time.monotonic() >= deadline:
                            self.fail("Descendant did not start")
                        time.sleep(0.02)
                marker.unlink()
                directory.rmdir()
            finally:
                if child_pid:
                    subprocess.run(["taskkill", "/PID", str(child_pid), "/T", "/F"],
                                   capture_output=True, check=False)
                for stream in (process.stdout, process.stderr):
                    stream.close()


if __name__ == "__main__":
    unittest.main()
