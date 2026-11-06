import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
import zipfile


from asset_fixtures import copy_asset_templates, run_with_assets

REPO = Path(__file__).resolve().parents[1]


class FontStagingTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="fonts ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        copy_asset_templates(self.source, ("fonts",))
        for name in ("dot_local/share/dotfiles/font-index.tsv.tmpl",):
            dest = self.source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / name, dest)
        self.data = self.source / ".chezmoidata"
        self.data.mkdir()
        self.config = self.root / "config.toml"
        self.config.write_text("", encoding="utf-8")
        self.payload = b"fixture desktop font"
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("public/static/Example.ttf", self.payload)
            archive.writestr("web/Example.woff2", b"webfont")
            archive.writestr("public/static/Example.otf", b"duplicate")
        self.archive = stream.getvalue()
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(fixture.archive)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.pin = {
            "url": f"http://127.0.0.1:{self.server.server_port}/fonts.zip",
            "sha256": hashlib.sha256(self.archive).hexdigest(), "format": "zip",
            "files": [{"path": "public/static/Example.ttf", "name": "Example.ttf",
                       "sha256": hashlib.sha256(self.payload).hexdigest()}],
        }
        self.write_data()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_CACHE_HOME=str(self.root / "cache"))

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def write_data(self):
        (self.data / "fonts.json").write_text(json.dumps({"fonts": {"example": {}}}))
        (self.data / "font-lock.json").write_text(json.dumps({"fontLocks": {"example": self.pin}}))

    def apply(self, *args, check=True):
        result = run_with_assets([
            "chezmoi", "--source", str(self.source), "--destination", str(self.home),
            "--config", str(self.config), "--cache", str(self.root / "cache"),
            "--persistent-state", str(self.root / "state.boltdb"), "--no-tty", "--force",
            *(args or ("apply",)),
        ], env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_verified_selection_and_staging_repair(self):
        self.apply()
        stage = self.home / ".local/share/dotfiles/font-assets/example"
        self.assertEqual((stage / "public/static/Example.ttf").read_bytes(), self.payload)
        self.assertEqual([p.name for p in stage.rglob("*") if p.is_file()], ["Example.ttf"])
        (stage / "public/static/Example.ttf").unlink()
        self.apply()
        self.assertEqual((stage / "public/static/Example.ttf").read_bytes(), self.payload)
        index = (self.home / ".local/share/dotfiles/font-index.tsv").read_text()
        self.assertEqual(index, "example\tpublic/static/Example.ttf\tExample.ttf\t" +
                         hashlib.sha256(self.payload).hexdigest() + "\n")

    def test_corrupt_archive_does_not_run_after_script(self):
        self.pin["sha256"] = "0" * 64
        self.write_data()
        scripts = self.source / ".chezmoiscripts"
        scripts.mkdir()
        marker = self.home / "after-marker"
        if os.name == "nt":
            script = scripts / "run_after_30-check.ps1"
            script.write_text("Set-Content -LiteralPath '" + str(marker).replace("'", "''") + "' -Value changed")
        else:
            script = scripts / "run_after_30-check.sh"
            script.write_text("#!/bin/sh\ntouch " + str(marker).replace("'", "'\\''").join(("'", "'")) + "\n")
        result = self.apply(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_missing_pin_fails_and_managed_does_not_apply_fonts(self):
        self.apply("managed", "--exclude=scripts")
        self.assertFalse((self.home / ".local").exists())
        (self.data / "font-lock.json").write_text('{"fontLocks": {}}')
        self.assertNotEqual(self.apply(check=False).returncode, 0)

    def render(self, relative, os_name, arch):
        context = {"chezmoi": {"os": os_name, "arch": arch,
                              "destDir": self.home.as_posix(), "workingTree": self.source.as_posix()},
                   "fonts": {"example": {}}, "fontLocks": {"example": self.pin}}
        template = (REPO / "home" / relative).read_text(encoding="utf-8")
        wrapper = ('{{ template "subject" (' + json.dumps(json.dumps(context)) + ' | fromJson) }}'
                   '{{ define "subject" }}' + template + '{{ end }}')
        result = subprocess.run(["chezmoi", "--source", str(self.source),
                                 "--destination", str(self.home), "--config", str(self.config),
                                 "execute-template"], input=wrapper, env=self.env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_platform_gates_match_staging_and_after_scripts(self):
        for os_name, arch in (("darwin", "amd64"), ("linux", "386"), ("freebsd", "amd64")):
            for path in (".chezmoitemplates/external-assets/fonts.toml.tmpl",
                         "dot_local/share/dotfiles/font-index.tsv.tmpl",
                         ".chezmoiscripts/run_after_30-install-fonts.ps1.tmpl",
                         ".chezmoiscripts/run_after_30-install-fonts.sh.tmpl"):
                self.assertFalse(self.render(path, os_name, arch).strip(), (path, os_name, arch))

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell wrapper")
    def test_windows_wrapper_preserves_apostrophes_and_spaces(self):
        scripts = self.source / "scripts"
        scripts.mkdir()
        (scripts / "install-fonts.ps1").write_text(
            "param($AssetRoot, $IndexPath, $FontDirectory, $StatePath)\n"
            "@($AssetRoot, $IndexPath, $FontDirectory, $StatePath) | ConvertTo-Json | "
            "Set-Content -LiteralPath $env:FONT_TRACE\n")
        launcher = self.root / "apply-fonts.ps1"
        launcher.write_text(self.render(".chezmoiscripts/run_after_30-install-fonts.ps1.tmpl", "windows", "amd64"),
                            encoding="utf-8-sig")
        trace = self.root / "args.json"
        env = dict(self.env, FONT_TRACE=str(trace), LOCALAPPDATA=str(self.root / "local data"))
        result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(launcher)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(trace.read_text(encoding="utf-8-sig"))
        self.assertEqual(Path(args[0]), self.home / ".local/share/dotfiles/font-assets")
        self.assertEqual(Path(args[2]), self.root / "local data/Microsoft/Windows/Fonts")

    def test_shell_wrapper_preserves_paths_and_xdg_override(self):
        shell = shutil.which("sh")
        if not shell and os.name == "nt":
            candidate = Path("C:/Program Files/Git/bin/sh.exe")
            shell = str(candidate) if candidate.exists() else None
        if not shell:
            self.skipTest("POSIX shell unavailable")
        scripts = self.source / "scripts"
        scripts.mkdir()
        (scripts / "install-fonts.sh").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FONT_TRACE"\n')
        for os_name in ("linux", "darwin"):
            launcher = self.root / "apply-fonts.sh"
            launcher.write_text(self.render(".chezmoiscripts/run_after_30-install-fonts.sh.tmpl", os_name, "arm64"))
            trace = self.root / "args.txt"
            data = (self.root / "custom data").as_posix()
            env = dict(self.env, FONT_TRACE=trace.as_posix(), XDG_DATA_HOME=data)
            result = subprocess.run([shell, str(launcher)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = trace.read_text().splitlines()
            self.assertEqual(Path(args[0]), self.home / ".local/share/dotfiles/font-assets")
            expected = Path(data) / "fonts/dotfiles" if os_name == "linux" else self.home / "Library/Fonts"
            self.assertEqual(Path(args[2]), expected)


if __name__ == "__main__":
    unittest.main()
