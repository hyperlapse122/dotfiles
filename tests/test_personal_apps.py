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
        for name in ("run_after_10-personal-app-path.ps1.tmpl",
                     "run_after_10-personal-app-path.sh.tmpl"):
            shutil.copy2(self.repo / "home" / name, self.source / name)
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

    def test_all_six_platforms_select_their_locked_target(self):
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
        result = self.render_external("freebsd", "amd64")
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
    def test_default_profile_and_highest_existing_login_profile(self):
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


if __name__ == "__main__":
    unittest.main()
