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
        for name in (".chezmoiexternals/fonts.toml.tmpl",
                     "dot_local/share/dotfiles/font-index.tsv.tmpl"):
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
        result = subprocess.run([
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


if __name__ == "__main__":
    unittest.main()
