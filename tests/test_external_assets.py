import ctypes
import errno
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import tomllib
import unittest
from unittest import mock
import zipfile

from smoke_personal_apps import temporary_destination
from asset_fixtures import preserve_mise_directories

REPO = Path(__file__).resolve().parents[1]


def native(path):
    """Reach paths past MAX_PATH on Windows hosts without LongPathsEnabled."""
    return Path("\\\\?\\" + str(path)) if os.name == "nt" else path


class ExternalAssetsTest(unittest.TestCase):
    def setUp(self):
        scratch = temporary_destination()
        self.root = Path(scratch.__enter__()).resolve()
        self.addCleanup(scratch.__exit__, None, None, None)
        self.home = self.root / "user home"
        self.home.mkdir()
        self.cache = self.root / "cache"
        self.manifest = self.root / "assets.toml"
        self.roots = self.root / "roots.tsv"
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running asset tests")
        self.payloads = {"/tool": b"first asset\n"}
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.requests.append(self.path)
                content = fixture.payloads.get(self.path)
                if content is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.stop_server, thread)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.env = dict(os.environ)
        preserve_mise_directories(self.env)
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home),
                        XDG_CONFIG_HOME=str(self.root / "config"),
                        XDG_CACHE_HOME=str(self.root / "xdg-cache"),
                        APPDATA=str(self.root / "config"),
                        LOCALAPPDATA=str(self.root / "local"),
                        PSModuleAnalysisCachePath=str(self.root / "module-analysis-cache"),
                        XDG_STATE_HOME=str(self.root / "state"))
        self.set_file()

    def stop_server(self, thread):
        self.server.shutdown()
        self.server.server_close()
        thread.join()

    def set_file(self, path="/tool", checksum=None):
        checksum = checksum or hashlib.sha256(self.payloads[path]).hexdigest()
        self.manifest.write_text(
            '[".local/bin/tool"]\ntype = "file"\n'
            f'url = "{self.url}{path}#sha256={checksum}"\n'
            f'checksum.sha256 = "{checksum}"\nexecutable = true\n', encoding="utf-8")
        self.roots.write_text(".local/bin/tool\tfile\tfalse\n", encoding="utf-8")

    def set_archive(self, files=None):
        files = files or {"tool": b"tool bytes", "data/config": b"configuration"}
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as stream:
            for name, content in files.items():
                stream.writestr("release/" + name, content)
        self.payloads["/bundle.zip"] = archive.getvalue()
        checksum = hashlib.sha256(archive.getvalue()).hexdigest()
        self.manifest.write_text(
            '[".local/resources"]\ntype = "archive"\n'
            f'url = "{self.url}/bundle.zip#sha256={checksum}"\n'
            f'checksum.sha256 = "{checksum}"\nformat = "zip"\nstripComponents = 1\nexact = true\n',
            encoding="utf-8")
        self.roots.write_text(".local/resources\tdirectory\ttrue\n", encoding="utf-8")

    def prepare(self, mode="normal", check=True):
        if os.name == "nt":
            command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                       "-File", str(REPO / "scripts/prepare-external-assets.ps1")]
        else:
            command = ["/bin/sh", str(REPO / "scripts/prepare-external-assets.sh")]
        command += [str(self.manifest), str(self.roots), str(self.home), str(self.cache), self.chezmoi, mode]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True,
                                encoding="utf-8", errors="backslashreplace", timeout=90)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def stage(self):
        generations = list((self.cache / "generations").glob("*/tree"))
        self.assertEqual(len(generations), 1)
        return generations[0]

    def test_cold_then_unchanged_run_reuses_assets(self):
        self.roots.write_text(self.roots.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        self.prepare()
        target = self.home / ".local/bin/tool"
        self.assertEqual(target.read_bytes(), b"first asset\n")
        before = target.stat().st_mtime_ns
        result = self.prepare()
        self.assertIn("Reusing prepared external assets", result.stdout)
        self.assertEqual(target.stat().st_mtime_ns, before)
        self.assertEqual(self.requests, ["/tool"])
        if os.name != "nt":
            self.assertTrue(os.access(target, os.X_OK))

    def test_real_before_script_prepares_and_repairs_assets(self):
        from asset_fixtures import copy_asset_templates

        source = self.root / "source with spaces '"
        source.mkdir()
        copy_asset_templates(source, ["personal-apps"])
        data = source / ".chezmoidata"
        data.mkdir()
        targets = {platform + "-" + arch: {} for platform in ("windows", "linux", "darwin")
                   for arch in ("amd64", "arm64")}
        checksum = hashlib.sha256(self.payloads["/tool"]).hexdigest()
        (data / "apps.json").write_text(json.dumps({"personalApps": {
            "fixture-app": {"command": "tool", "targets": targets}}}), encoding="utf-8")
        (data / "locks.json").write_text(json.dumps({"personalAppLocks": {
            "fixture-app": {"targets": {target: {"kind": "file", "url": self.url + "/tool",
                "sha256": checksum} for target in targets}}}}), encoding="utf-8")
        (source / "scripts").mkdir()
        scripts = source / ".chezmoiscripts"
        scripts.mkdir()
        extension = "ps1" if os.name == "nt" else "sh"
        shutil.copy2(REPO / "scripts" / ("prepare-external-assets." + extension), source / "scripts")
        launcher = "run_before_05-external-assets." + extension + ".tmpl"
        shutil.copy2(REPO / "home/.chezmoiscripts" / launcher, scripts)
        (source / ".chezmoiignore").write_text("scripts\n", encoding="utf-8")
        config = self.root / "outer.toml"
        config.write_text("", encoding="utf-8")
        command = [self.chezmoi, "--config", str(config), "--source", str(source),
                   "--destination", str(self.home), "--cache", str(self.cache),
                   "--persistent-state", str(self.root / "outer.boltdb"), "apply", "--force"]
        target = self.home / ".local/bin" / ("tool.exe" if os.name == "nt" else "tool")
        for iteration in range(3):
            if iteration == 2:
                target.unlink()
            result = subprocess.run(command, env=self.env, capture_output=True, text=True,
                                    encoding="utf-8", errors="backslashreplace", timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(target.read_bytes(), self.payloads["/tool"])
        self.assertEqual(self.requests, ["/tool"])

    def test_deleted_destination_repairs_without_download(self):
        self.set_archive()
        self.prepare()
        target = self.home / ".local/resources/data/config"
        target.unlink()
        self.prepare()
        self.assertEqual(target.read_bytes(), b"configuration")
        self.assertEqual(self.requests, ["/bundle.zip"])

    def test_completion_and_enrolled_ca_assets_share_preparation_and_repair(self):
        bash_files = {
            "bash_completion": b"completion library\n",
            "startup-core/000_bash_completion_compat.bash": b"compatibility definitions\n",
            "COPYING": b"license\n",
        }
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as stream:
            for name, content in bash_files.items():
                stream.writestr("bash-completion-2.18.0/" + name, content)
            stream.writestr("bash-completion-2.18.0/not-selected", b"unneeded")
        self.payloads["/completion.zip"] = archive.getvalue()
        self.payloads["/cacert.pem"] = b"public root fixture\n"
        source = self.root / "enrollment source"
        (source / ".secrets").mkdir(parents=True)
        # Membership selects the asset; rendering must never decrypt this file.
        (source / ".secrets/ca-certificates.json.asc").write_text("inert enrollment marker")
        bash_pin = {"url": self.url + "/completion.zip",
                    "sha256": hashlib.sha256(self.payloads["/completion.zip"]).hexdigest()}
        ca_pin = {"url": self.url + "/cacert.pem",
                  "sha256": hashlib.sha256(self.payloads["/cacert.pem"]).hexdigest()}
        context = ('{{ $ctx := . | setValueAtPath "chezmoi.os" "linux" '
                   '| setValueAtPath "chezmoi.arch" "amd64" '
                   '| setValueAtPath "chezmoi.osRelease.id" "debian" '
                   '| setValueAtPath "chezmoi.sourceDir" ' + json.dumps(str(source))
                   + ' | setValueAtPath "cliCompletionAssets.bashCompletion" (fromJson '
                   + json.dumps(json.dumps(bash_pin)) + ') '
                   + '| setValueAtPath "caFilesPublicRoots" (fromJson '
                   + json.dumps(json.dumps(ca_pin)) + ') }}'
                   + '{{ includeTemplate "external-assets-manifest" $ctx }}')
        config = self.root / "render.toml"
        config.write_text("")
        rendered = subprocess.run([self.chezmoi, "--source", str(REPO), "--config", str(config),
                                   "execute-template", context], env=self.env,
                                  capture_output=True, text=True, timeout=30)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        assets = tomllib.loads(rendered.stdout)
        bash_root = ".local/share/dotfiles/bash-completion"
        ca_root = ".local/share/dotfiles/ca/public-roots.pem"
        self.assertIn(bash_root, assets.keys())
        self.assertIn(ca_root, assets.keys())
        selected = {path: assets[path] for path in (bash_root, ca_root)}
        # Bash uses a ZIP transport fixture; selection and ownership come from
        # the real shared declarations, including the directly downloaded PEM.
        selected[bash_root]["format"] = "zip"
        lines = []
        for path, declaration in selected.items():
            lines.append("[" + json.dumps(path) + "]")
            for key, value in declaration.items():
                if isinstance(value, dict):
                    lines.extend(f"{key}.{field} = {json.dumps(item)}" for field, item in value.items())
                else:
                    lines.append(f"{key} = {json.dumps(value)}")
        self.manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.roots.write_text(f"{bash_root}\tdirectory\ttrue\n{ca_root}\tfile\tfalse\n")
        self.prepare()
        for name, content in bash_files.items():
            self.assertEqual((self.home / bash_root / name).read_bytes(), content)
        self.assertFalse((self.home / bash_root / "not-selected").exists())
        self.assertEqual((self.home / ca_root).read_bytes(), b"public root fixture\n")
        private_bundle = self.home / ".local/share/dotfiles/ca/bundle.pem"
        private_bundle.write_bytes(b"last valid combined bundle\n")
        self.assertIn("Reusing prepared external assets", self.prepare().stdout)
        (self.home / bash_root / "bash_completion").unlink()
        (self.home / ca_root).unlink()
        self.prepare()
        self.assertEqual((self.home / bash_root / "bash_completion").read_bytes(), bash_files["bash_completion"])
        self.assertEqual((self.home / ca_root).read_bytes(), b"public root fixture\n")
        self.assertCountEqual(self.requests, ["/completion.zip", "/cacert.pem"])
        self.assertEqual(private_bundle.read_bytes(), b"last valid combined bundle\n")
        # A forced download of changed upstream bytes must retain both outputs.
        self.payloads["/cacert.pem"] = b"unexpected upstream revision\n"
        result = self.prepare("refresh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / ca_root).read_bytes(), b"public root fixture\n")
        self.assertEqual(private_bundle.read_bytes(), b"last valid combined bundle\n")

    def test_changed_pin_at_same_url_prepares_new_content(self):
        self.prepare()
        self.payloads["/tool"] = b"replacement\n"
        self.set_file()
        self.prepare()
        self.assertEqual((self.home / ".local/bin/tool").read_bytes(), b"replacement\n")
        self.assertEqual(self.requests, ["/tool", "/tool"])

    @unittest.skipUnless(os.name == "nt", "Windows native preparation long-path boundary")
    def test_long_archive_members_prepare_reuse_and_repair(self):
        member = "skills/ce-work/references/" + "/".join(["nested-resource"] * 5) + "/details.txt"
        self.set_archive({member: b"long native resource\n"})
        self.prepare()
        staged = self.stage() / ".local/resources" / member
        self.assertGreater(len(str(staged)), 260)
        self.assertEqual(Path("\\\\?\\" + str(staged)).read_bytes(), b"long native resource\n")
        target = self.home / ".local/resources" / member
        self.assertEqual(target.read_bytes(), b"long native resource\n")
        target.unlink()
        self.prepare()
        self.assertEqual(target.read_bytes(), b"long native resource\n")
        self.assertIn("Reusing prepared external assets", self.prepare().stdout)
        self.assertEqual(self.requests, ["/bundle.zip"])

    def test_bad_checksum_does_not_replace_installed_asset(self):
        self.prepare()
        self.payloads["/bad"] = b"wrong bytes"
        self.set_file("/bad", hashlib.sha256(b"expected bytes").hexdigest())
        result = self.prepare(check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / ".local/bin/tool").read_bytes(), b"first asset\n")
        self.assertEqual(len(list((self.cache / "generations").glob("*/prepared"))), 1)

    def test_exact_root_prunes_only_owned_tree(self):
        self.set_archive()
        self.prepare()
        stale = self.home / ".local/resources/stale"
        stale.write_bytes(b"remove")
        unrelated = self.home / ".local/bin/owner-tool"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_bytes(b"keep")
        self.prepare()
        self.assertFalse(stale.exists())
        self.assertEqual(unrelated.read_bytes(), b"keep")

    def test_paths_beyond_windows_max_path_are_prepared_and_pruned(self):
        # Windows PowerShell 5.1 is not long-path aware even with LongPathsEnabled set.
        deep = "/".join(["nested-directory-segment"] * 9) + "/payload.txt"
        for owned in (self.cache, self.home / ".local"):
            self.addCleanup(shutil.rmtree, native(owned), True)
        self.set_archive({deep: b"deep"})
        self.prepare()
        staged = self.stage() / ".local/resources" / deep
        self.assertGreater(len(str(staged)), 260)
        target = self.home / ".local/resources" / deep
        self.assertEqual(native(target).read_bytes(), b"deep")
        (self.stage().parent / "prepared").unlink()
        stale = target.with_name("stale.txt")
        native(stale).write_bytes(b"remove")
        self.prepare()
        self.assertFalse(native(stale).exists())
        self.assertEqual(native(target).read_bytes(), b"deep")
        self.assertEqual(self.requests, ["/bundle.zip"])

    def test_verify_repairs_preserved_metadata_corruption(self):
        self.prepare()
        target = self.home / ".local/bin/tool"
        before = target.stat()
        target.write_bytes(b"other asset\n")
        os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.prepare("verify")
        self.assertEqual(target.read_bytes(), b"first asset\n")
        self.assertEqual(self.requests, ["/tool"])

    def test_refresh_redownloads_same_url(self):
        self.prepare()
        self.prepare("refresh")
        self.assertEqual(self.requests, ["/tool", "/tool"])

    def test_damaged_staged_tree_is_rebuilt_before_reconciliation(self):
        self.prepare()
        staged = self.stage() / ".local/bin/tool"
        staged.write_bytes(b"corrupted stage")
        (self.home / ".local/bin/tool").unlink()
        self.prepare()
        self.assertEqual((self.home / ".local/bin/tool").read_bytes(), b"first asset\n")
        self.assertEqual(self.requests, ["/tool"])

    def test_unfinished_preparation_retries(self):
        self.prepare()
        generation = self.stage().parent
        (generation / "prepared").unlink()
        (generation / "tree/.local/bin/tool").write_bytes(b"partial")
        self.prepare()
        self.assertEqual((generation / "tree/.local/bin/tool").read_bytes(), b"first asset\n")

    def test_nested_configuration_ignores_personal_hooks(self):
        marker = self.home / "hook-ran"
        config = self.root / "config/chezmoi/chezmoi.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[hooks.apply.pre]\ncommand = "does-not-exist-hook"\n', encoding="utf-8")
        self.prepare()
        self.assertFalse(marker.exists())

    def test_empty_manifest_is_noop(self):
        self.manifest.write_text("", encoding="utf-8")
        for content in ("", "\n", "\n\n"):
            with self.subTest(roots=repr(content)):
                self.roots.write_text(content, encoding="utf-8")
                self.prepare()
        self.assertEqual(self.requests, [])
        self.assertFalse((self.home / ".local").exists())

    def test_unsafe_root_is_rejected(self):
        self.roots.write_text("../owner\tfile\tfalse\n", encoding="utf-8")
        self.assertNotEqual(self.prepare(check=False).returncode, 0)
        self.assertFalse((self.root / "owner").exists())

    @unittest.skipUnless(os.name == "nt", "Windows refuses to replace running executables")
    def test_in_use_installed_file_is_replaced(self):
        self.prepare()
        target = self.home / ".local/bin/tool"
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                      ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        # Read and delete sharing matches a mapped executable: rename works, replacement does not.
        handle = kernel.CreateFileW(str(target), 0x80000000, 0x1 | 0x4, None, 3, 0, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            self.payloads["/tool"] = b"replacement\n"
            self.set_file()
            self.prepare()
            self.assertEqual(target.read_bytes(), b"replacement\n")
        finally:
            kernel.CloseHandle(handle)
        self.payloads["/tool"] = b"third\n"
        self.set_file()
        self.prepare()
        self.assertEqual(list((self.cache / "retired").iterdir()), [])

    @unittest.skipUnless(os.name == "nt", "Windows file sharing proves metadata-only warm path")
    def test_warm_run_never_opens_payload_bytes(self):
        declaration = self.manifest.read_text(encoding="utf-8")
        self.manifest.write_text(declaration + declaration.replace('.local/bin/tool', '.local/bin/other'),
                                 encoding="utf-8")
        self.roots.write_text(".local/bin/tool\tfile\tfalse\n.local/bin/other\tfile\tfalse\n",
                              encoding="utf-8")
        self.prepare()
        paths = [self.home / ".local/bin/tool", self.stage() / ".local/bin/tool"]
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                      ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handles = []
        try:
            for path in paths:
                handle = kernel.CreateFileW(str(path), 0x80000000, 0, None, 3, 0, None)
                self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
                handles.append(handle)
            self.assertIn("Reusing prepared external assets", self.prepare().stdout)
            other = self.home / ".local/bin/other"
            other.unlink()
            self.prepare()
            self.assertEqual(other.read_bytes(), b"first asset\n")
        finally:
            for handle in handles:
                kernel.CloseHandle(handle)


class TemporaryDestinationTest(unittest.TestCase):
    def test_cleanup_retries_directory_populated_during_removal(self):
        original = os.rmdir
        injected = False

        def late_write(path, *args, **kwargs):
            nonlocal injected
            if not injected and str(path).endswith("user home"):
                injected = True
                (home / "late-state.json").write_text("{}")
            return original(path, *args, **kwargs)

        with mock.patch("os.rmdir", side_effect=late_write):
            with temporary_destination() as scratch:
                home = Path(scratch) / "user home"
                home.mkdir()
        self.assertTrue(injected)
        self.assertFalse(Path(scratch).exists())

    def test_cleanup_propagates_unrelated_errors(self):
        with mock.patch("smoke_personal_apps.shutil.rmtree", side_effect=OSError(errno.EIO, "fixture")):
            with self.assertRaises(OSError) as error:
                with temporary_destination() as scratch:
                    pass
        self.assertEqual(error.exception.errno, errno.EIO)
        shutil.rmtree(scratch)

    def test_cleanup_stops_retrying_a_persistent_writer(self):
        error = OSError(errno.ENOTEMPTY, "fixture")
        with mock.patch("smoke_personal_apps.shutil.rmtree", side_effect=error) as remove, mock.patch("smoke_personal_apps.time.sleep"):
            with self.assertRaises(OSError):
                with temporary_destination() as scratch:
                    pass
        self.assertEqual(remove.call_count, 5)
        shutil.rmtree(scratch)
