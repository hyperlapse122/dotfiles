import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import tomllib
import unittest
import uuid

if os.name == "nt":
    import winreg


class PersonalAppsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running personal app tests")
        self.scratch = tempfile.TemporaryDirectory(prefix="personal apps ' ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for directory in (".chezmoidata", ".chezmoiexternals", "dot_config"):
            shutil.copytree(self.repo / "home" / directory, self.source / directory)
        for name in (".chezmoiscripts/run_onchange_after_10-personal-app-path.ps1.tmpl",
                     ".chezmoiscripts/run_onchange_after_10-personal-app-path.sh.tmpl"):
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.repo / "home" / name, target)
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.pop("ZDOTDIR", None)
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.payloads = {"/omp": b"#!/bin/sh\nprintf 'first\\n'\n"}
        self.requests = []
        payloads, requests = self.payloads, self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                payload = payloads.get(self.path)
                if payload is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.base_url = "http://127.0.0.1:" + str(self.server.server_port)
        self.apps = json.loads((self.source / ".chezmoidata" / "personal-apps.json").read_text(encoding="utf-8"))
        self.set_pin()
        self.binary = self.home / ".local" / "bin" / ("omp.exe" if os.name == "nt" else "omp")

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def set_pin(self, path="/omp", checksum=None):
        checksum = checksum or hashlib.sha256(self.payloads[path]).hexdigest()
        self.locks = {"personalAppLocks": {"omp": {
            "tag": "fixture", "targets": {
                target: {"url": self.base_url + path, "sha256": checksum}
                for target in self.apps["personalApps"]["omp"]["targets"]
            },
        }}}
        self.write_locks()

    def write_locks(self):
        (self.source / ".chezmoidata" / "personal-app-lock.json").write_text(
            json.dumps(self.locks), encoding="utf-8")

    def run_chezmoi(self, *args, input=None):
        return subprocess.run(
            [self.chezmoi, "--config", str(self.config), "--source", str(self.source),
             "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
             "--persistent-state", str(self.root / "chezmoi-state.boltdb"), *args],
            env=self.env, input=input, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )

    def apply(self, scripts=False):
        # Even on Windows this fixture can never execute a registry-writing script.
        if scripts and os.name == "nt":
            self.fail("Persistent Windows PATH tests belong on disposable CI runners")
        args = ("apply", "--force") if scripts else ("apply", "--force", "--exclude=scripts")
        result = self.run_chezmoi(*args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_install_reapply_and_reconcile_changed_url(self):
        first = self.payloads["/omp"]
        self.apply()
        self.assertEqual(self.binary.read_bytes(), first)
        if os.name != "nt":
            self.assertTrue(os.access(self.binary, os.X_OK))
        self.assertEqual(self.requests, ["/omp"])
        self.apply()
        self.assertEqual(self.binary.read_bytes(), first)
        self.assertEqual(self.requests, ["/omp"])
        self.payloads["/next"] = b"updated release bytes\n"
        self.set_pin("/next")
        self.apply()
        self.assertEqual(self.binary.read_bytes(), self.payloads["/next"])
        self.assertEqual(self.requests, ["/omp", "/next"])
        # Reconcile destination drift too, without another network request.
        self.binary.write_bytes(b"local drift")
        self.apply()
        self.assertEqual(self.binary.read_bytes(), self.payloads["/next"])
        self.assertEqual(self.requests, ["/omp", "/next"])

    def test_checksum_only_change_at_same_url_fetches_replacement(self):
        self.apply()
        self.payloads["/omp"] = b"replacement at the same release URL\n"
        self.set_pin()
        self.apply()
        self.assertEqual(self.binary.read_bytes(), self.payloads["/omp"])
        self.assertEqual(self.requests, ["/omp", "/omp"])

    def test_bad_checksum_preserves_installed_executable(self):
        self.apply()
        original = self.binary.read_bytes()
        self.payloads["/corrupt"] = b"corrupt download"
        self.set_pin("/corrupt", hashlib.sha256(b"expected release").hexdigest())
        result = self.run_chezmoi("apply", "--force", "--exclude=scripts")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), original)
        self.assertEqual(self.requests, ["/omp", "/corrupt"])

    def render_external(self, os_name, arch):
        template = (self.source / ".chezmoiexternals" / "personal-apps.toml.tmpl").read_text(encoding="utf-8")
        wrapper = ('{{ template "external" (dict "chezmoi" (dict "os" '
                   + json.dumps(os_name) + ' "arch" ' + json.dumps(arch)
                   + ') "personalApps" .personalApps "personalAppLocks" .personalAppLocks) }}'
                   + '{{ define "external" }}' + template + '{{ end }}')
        return self.run_chezmoi("execute-template", input=wrapper)

    def test_supported_platforms_select_their_locked_target(self):
        targets = self.apps["personalApps"]["omp"]["targets"]
        for number, target in enumerate(targets):
            self.locks["personalAppLocks"]["omp"]["targets"][target] = {
                "url": self.base_url + "/" + target, "sha256": f"{number + 1:064x}",
            }
        self.write_locks()
        for target in targets:
            with self.subTest(target=target):
                os_name, arch = target.split("-")
                result = self.render_external(os_name, arch)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                rendered = tomllib.loads(result.stdout)
                command = ".local/bin/omp" + (".exe" if os_name == "windows" else "")
                self.assertEqual(list(rendered), [command])
                entry = rendered[command]
                pin = self.locks["personalAppLocks"]["omp"]["targets"][target]
                self.assertEqual(entry["type"], "file")
                self.assertTrue(entry["executable"])
                self.assertEqual(entry["url"], pin["url"] + "#sha256=" + pin["sha256"])
                self.assertEqual(entry["checksum"]["sha256"], pin["sha256"])
        self.assertEqual(self.requests, [])

    def test_unsupported_platform_emits_no_app(self):
        self.locks["personalAppLocks"]["omp"]["targets"]["darwin-amd64"] = (
            self.locks["personalAppLocks"]["omp"]["targets"]["linux-amd64"]
        )
        self.write_locks()
        for os_name, arch in (("freebsd", "amd64"), ("darwin", "amd64")):
            with self.subTest(os=os_name, arch=arch):
                result = self.render_external(os_name, arch)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(tomllib.loads(result.stdout), {})
        self.assertEqual(self.requests, [])

    def test_missing_supported_target_pin_fails(self):
        self.locks["personalAppLocks"]["omp"]["targets"].pop("linux-arm64")
        self.write_locks()
        result = self.render_external("linux", "arm64")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Missing personal application pin", result.stderr)
        self.assertEqual(self.requests, [])

    def test_bootstrap_managed_is_download_and_path_action_free(self):
        # Match the unchanged bootstrap task's command and isolated configuration.
        shutil.copy2(self.repo / ".chezmoi-bootstrap.toml", self.config)
        result = self.run_chezmoi("managed", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(".local/bin/omp", result.stdout.replace("\\", "/"))
        self.assertEqual(self.requests, [])
        self.assertFalse(self.binary.exists())
        self.assertEqual(list(self.home.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "POSIX shell startup files")
    def test_profiles_preserve_existing_bash_login_precedence_and_zdotdir(self):
        login = self.home / ".bash_login"
        original = "# existing login without final newline"
        login.write_text(original, encoding="utf-8")
        lower = self.home / ".profile"
        lower.write_text("# lower precedence\n", encoding="utf-8")
        bashrc = self.home / ".bashrc"
        bashrc.write_text("# existing interactive settings\n", encoding="utf-8")
        zdotdir = self.home / "zsh startup ' files"
        self.env["ZDOTDIR"] = str(zdotdir)
        self.apply(scripts=True)
        self.assertFalse((self.home / ".bash_profile").exists())
        self.assertEqual(lower.read_text(encoding="utf-8"), "# lower precedence\n")
        self.assertTrue(login.read_text(encoding="utf-8").startswith(original + "\n"))
        self.assertTrue(bashrc.read_text(encoding="utf-8").startswith("# existing interactive settings\n"))
        self.assertFalse((self.home / ".zprofile").exists())
        profiles = [login, bashrc, zdotdir / ".zprofile", zdotdir / ".zshrc"]
        contents = {path: path.read_bytes() for path in profiles}
        self.apply(scripts=True)
        self.assertEqual({path: path.read_bytes() for path in profiles}, contents)
        self.assert_startup_resolves_command(login)
        self.assert_startup_resolves_command(bashrc)

    @unittest.skipIf(os.name == "nt", "POSIX shell startup files")
    def test_profile_actions_use_destination_not_process_home(self):
        other_home = self.root / "different process home"
        other_home.mkdir()
        self.env["HOME"] = str(other_home)
        self.apply(scripts=True)
        self.assertTrue((self.home / ".profile").is_file())
        self.assertTrue((self.home / ".bashrc").is_file())
        self.assertEqual(list(other_home.iterdir()), [])

    @unittest.skipIf(os.name == "nt", "POSIX shell startup files")
    def test_new_login_profile_is_integrated_only_after_fragment_change(self):
        self.apply(scripts=True)
        self.assertFalse((self.home / ".bash_profile").exists())
        self.assertFalse((self.home / ".bash_login").exists())
        self.assert_startup_resolves_command(self.home / ".profile")
        (self.home / ".bash_profile").write_text("# highest priority\n", encoding="utf-8")
        (self.home / ".bash_login").write_text("# second priority\n", encoding="utf-8")
        lower = (self.home / ".profile").read_bytes()
        self.apply(scripts=True)
        self.assertEqual((self.home / ".profile").read_bytes(), lower)
        self.assertEqual((self.home / ".bash_login").read_text(encoding="utf-8"), "# second priority\n")
        self.assertEqual((self.home / ".bash_profile").read_text(encoding="utf-8"), "# highest priority\n")
        with (self.source / "dot_config/dotfiles/path.sh").open("a", encoding="utf-8") as stream:
            stream.write("\n# update PATH integration\n")
        self.apply(scripts=True)
        self.assert_startup_resolves_command(self.home / ".bash_profile")

    def assert_startup_resolves_command(self, profile):
        shell = shutil.which("sh")
        self.assertIsNotNone(shell, "POSIX tests require sh")
        result = subprocess.run(
            [shell, "-c", '. "$1"; . "$1"; command -v omp; printf "%s\\n" "$PATH"', "sh", str(profile)],
            env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], str(self.binary))
        self.assertEqual(lines[1].split(os.pathsep).count(str(self.binary.parent)), 1)


class PersonalAppPathTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.assertIsNotNone(shutil.which("chezmoi"), "Install chezmoi before running PATH tests")
        scratch = tempfile.TemporaryDirectory(prefix="personal app path ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        for relative in (
            ".chezmoiscripts/run_onchange_after_10-personal-app-path.ps1.tmpl",
            ".chezmoiscripts/run_onchange_after_10-personal-app-path.sh.tmpl",
            "dot_config/dotfiles/path.sh",
            ".chezmoidata/personal-apps.json",
            ".chezmoidata/personal-app-lock.json",
        ):
            target = self.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.repo / "home" / relative, target)
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.pop("ZDOTDIR", None)
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        if os.name == "nt":
            self.registry_path = "Software\\dotfiles-personal-path-test-" + uuid.uuid4().hex
            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.registry_path) as key:
                winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, "%USERPROFILE%\\keep")
            self.addCleanup(winreg.DeleteKey, winreg.HKEY_CURRENT_USER, self.registry_path)
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            wrapper = self.root / "isolated-interpreter.ps1"
            # The production body uses .NET directly, so PSDrive redirection cannot isolate it.
            wrapper.write_text(
                "param([string]$Script)\n$ErrorActionPreference = 'Stop'\n"
                "$body = [IO.File]::ReadAllText($Script)\n"
                "$call = \"[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')\"\n"
                "if (-not $body.Contains($call)) { throw 'Cannot isolate PATH registry write' }\n"
                "$body = $body.Replace($call, "
                f"\"[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('{self.registry_path}')\")\n"
                "& ([scriptblock]::Create($body))\n", encoding="utf-8-sig",
            )
            self.config.write_text(
                "[interpreters.ps1]\ncommand = " + json.dumps(str(shell)) +
                "\nargs = " + json.dumps(["-NoLogo", "-NoProfile", "-NonInteractive",
                                          "-ExecutionPolicy", "Bypass", "-File", str(wrapper)]) + "\n",
                encoding="utf-8",
            )

    def chezmoi(self, *args):
        result = subprocess.run(
            ["chezmoi", "--config", str(self.config), "--source", str(self.source),
             "--destination", str(self.home), "--cache", str(self.root / "cache"),
             "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", *args],
            env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def apply(self):
        self.chezmoi("apply", "--force")

    def remove_integration(self):
        if os.name == "nt":
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry_path, 0, winreg.KEY_SET_VALUE) as key:
                winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, "%USERPROFILE%\\manual")
        else:
            (self.home / ".bashrc").write_text("# manual removal\n", encoding="utf-8")

    def assert_integration(self):
        if os.name == "nt":
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry_path) as key:
                value, kind = winreg.QueryValueEx(key, "Path")
            self.assertEqual(kind, winreg.REG_EXPAND_SZ)
            self.assertIn(str(self.home / ".local" / "bin"), value.split(";"))
            self.assertTrue(value.startswith("%USERPROFILE%\\"))
        else:
            env = {**self.env, "HOME": str(self.home), "PATH": os.defpath}
            result = subprocess.run(
                ["sh", "-c", '. "$1"; printf "%s\\n" "$PATH"', "sh", str(self.home / ".bashrc")],
                env=env, capture_output=True, text=True, encoding="utf-8", timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip().split(os.pathsep).count(str(self.home / ".local/bin")), 1)

    def assert_integration_absent(self):
        if os.name == "nt":
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.registry_path) as key:
                self.assertEqual(winreg.QueryValueEx(key, "Path"),
                                 ("%USERPROFILE%\\manual", winreg.REG_EXPAND_SZ))
        else:
            self.assertEqual((self.home / ".bashrc").read_text(encoding="utf-8"), "# manual removal\n")

    def test_unchanged_apply_does_not_restore_host_only_path_drift(self):
        self.apply()
        self.assert_integration()
        self.remove_integration()
        self.apply()
        self.assert_integration_absent()

    def test_application_pin_change_does_not_schedule_path_action(self):
        self.apply()
        self.remove_integration()
        lock = self.source / ".chezmoidata/personal-app-lock.json"
        data = json.loads(lock.read_text(encoding="utf-8"))
        data["personalAppLocks"]["omp"]["tag"] = "unrelated-release"
        lock.write_text(json.dumps(data, indent=4), encoding="utf-8")
        self.assertNotIn("personal-app-path", self.chezmoi("status").stdout)
        self.apply()
        self.assert_integration_absent()

    def test_destination_change_schedules_path_action(self):
        self.apply()
        self.home = self.root / "different destination"
        self.home.mkdir()
        self.assertIn("personal-app-path", self.chezmoi("status").stdout)
        self.apply()
        self.assert_integration()

    @unittest.skipIf(os.name == "nt", "POSIX shell startup files")
    def test_fragment_source_change_reintegrates_profiles(self):
        self.apply()
        self.remove_integration()
        fragment = self.source / "dot_config/dotfiles/path.sh"
        with fragment.open("a", encoding="utf-8") as stream:
            stream.write("\n# consumed fragment changed\n")
        self.assertIn("personal-app-path", self.chezmoi("status").stdout)
        self.apply()
        self.assert_integration()

    @unittest.skipIf(os.name == "nt", "POSIX shell startup files")
    def test_effective_zdotdir_change_integrates_new_startup_location(self):
        self.apply()
        zdotdir = self.root / "new zsh home"
        self.env["ZDOTDIR"] = str(zdotdir)
        self.assertIn("personal-app-path", self.chezmoi("status").stdout)
        self.apply()
        self.assertIn(".config/dotfiles/path.sh", (zdotdir / ".zprofile").read_text(encoding="utf-8"))
        self.assertIn(".config/dotfiles/path.sh", (zdotdir / ".zshrc").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
