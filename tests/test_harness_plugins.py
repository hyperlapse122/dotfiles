from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import tomllib
import unittest


from asset_fixtures import copy_asset_templates, run_with_assets

class AntigravityAuthenticationTest(unittest.TestCase):
    def test_authenticated_completion_without_skill_read_is_rejected(self):
        from smoke_antigravity import verify_authenticated_invocation
        with tempfile.TemporaryDirectory() as scratch:
            skill = Path(scratch) / "SKILL.md"
            skill.write_text("# Pinned skill\n", encoding="utf-8")
            events = json.dumps({"event": "result", "result": {"status": "SUCCESS",
                "response": "The dotfiles verification returned AGY_CE_NATIVE_OK."}})
            with self.assertRaisesRegex(RuntimeError, "skill read"):
                verify_authenticated_invocation(events, skill)

    def test_authenticated_completion_requires_full_selected_skill_read(self):
        from smoke_antigravity import verify_authenticated_invocation
        with tempfile.TemporaryDirectory() as scratch:
            skill = Path(scratch) / "SKILL.md"
            skill.write_bytes(b"# Pinned skill\n")
            read = {"event": "step_update", "step_update": {"state": "DONE", "step_type": "tool",
                "tool_name": "read_file", "tool_info": {"parameters": {"Path": str(skill)},
                "output": "1 lines, 15 bytes"}}}
            result = {"event": "result", "result": {"status": "SUCCESS",
                "response": "The dotfiles verification returned AGY_CE_NATIVE_OK."}}
            verify_authenticated_invocation("\n".join(map(json.dumps, [read, result])), skill)
            read["step_update"]["tool_info"]["output"] = "1 lines, 2 bytes"
            with self.assertRaisesRegex(RuntimeError, "skill read"):
                verify_authenticated_invocation("\n".join(map(json.dumps, [read, result])), skill)

    def test_authenticated_smoke_requires_explicit_api_key(self):
        from smoke_antigravity import authenticated_environment
        with self.assertRaisesRegex(RuntimeError, "GEMINI_API_KEY"):
            authenticated_environment({}, {"HOME": "/disposable"})

    def test_authenticated_smoke_keeps_disposable_home_and_official_endpoint(self):
        from smoke_antigravity import authenticated_environment
        result = authenticated_environment(
            {"GEMINI_API_KEY": "inert-test-key", "GOOGLE_GEMINI_BASE_URL": "http://example.invalid"},
            {"HOME": "/disposable", "GOOGLE_GEMINI_BASE_URL": "http://capture.invalid"})
        self.assertEqual(result["HOME"], "/disposable")
        self.assertEqual(result["GEMINI_API_KEY"], "inert-test-key")
        self.assertNotIn("GOOGLE_GEMINI_BASE_URL", result)

class HarnessPluginsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running harness plugin tests")
        self.scratch = tempfile.TemporaryDirectory(prefix="harness plugins ' ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for directory in (".chezmoidata", ".chezmoitemplates", "private_dot_gemini"):
            shutil.copytree(self.repo / "home" / directory, self.source / directory)
        shutil.copy2(self.repo / "home/.chezmoiignore", self.source / ".chezmoiignore")
        copy_asset_templates(self.source, ("harness-plugins",))
        self.external = self.source / ".chezmoitemplates/external-assets/harness-plugins.toml.tmpl"
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.first_sha = "1" * 40
        self.next_sha = "2" * 40
        self.payloads = {}
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
        # Only redirect archive transport; pin selection and extraction stay native.
        self.external.write_text(self.external.read_text(encoding="utf-8").replace(
            "https://github.com", self.base_url), encoding="utf-8")
        self.declarations = json.loads((self.source / ".chezmoidata/harness-plugins.json").read_text(encoding="utf-8"))
        self.declarations["harnessPlugins"]["compound-engineering"]["repository"] = "fixture/source"
        (self.source / ".chezmoidata/harness-plugins.json").write_text(json.dumps(self.declarations), encoding="utf-8")
        self.add_archive(self.first_sha, {"skills/example/SKILL.md": "first revision\n", "old-only": "old\n"})
        self.add_archive(self.next_sha, {"skills/example/SKILL.md": "next revision\n", "new-only": "new\n"})
        self.set_pin(self.first_sha)
        self.tree = self.home / ".local/share/dotfiles/harness-plugins/compound-engineering"

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def add_archive(self, sha, files):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, text in files.items():
                data = text.encode("utf-8")
                info = tarfile.TarInfo("source-" + sha + "/" + name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        self.payloads["/fixture/source/archive/" + sha + ".tar.gz"] = stream.getvalue()

    def set_pin(self, sha):
        (self.source / ".chezmoidata/harness-plugin-lock.json").write_text(json.dumps({
            "harnessPluginLocks": {"compound-engineering": {"tag": "compound-engineering-v1.0.0", "commit": sha}},
        }), encoding="utf-8")

    def run_chezmoi(self, *args, input=None):
        return run_with_assets(
            [self.chezmoi, "--config", str(self.config), "--source", str(self.source),
             "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
             "--persistent-state", str(self.root / "chezmoi-state.boltdb"), *args],
            env=self.env, input=input, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )

    def apply(self):
        result = self.run_chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_pins_are_stable_and_changes_rollback_exactly(self):
        outside = self.tree.parent / "unrelated-plugin/state"
        outside.parent.mkdir(parents=True)
        outside.write_text("keep", encoding="utf-8")
        self.apply()
        self.assertEqual((self.tree / "skills/example/SKILL.md").read_text(encoding="utf-8"), "first revision\n")
        self.assertTrue((self.tree / "old-only").exists())
        self.assertFalse((self.tree / "new-only").exists())
        self.assertEqual(self.requests, ["/fixture/source/archive/" + self.first_sha + ".tar.gz"])
        # New upstream content does not move an unchanged repository pin.
        self.add_archive("3" * 40, {"skills/example/SKILL.md": "upstream latest\n"})
        self.apply()
        self.assertEqual(len(self.requests), 1)
        (self.tree / "skills/example/SKILL.md").write_text("drift", encoding="utf-8")
        (self.tree / "unmanaged-drift").write_text("drift", encoding="utf-8")
        self.apply()
        self.assertEqual((self.tree / "skills/example/SKILL.md").read_text(encoding="utf-8"), "first revision\n")
        self.assertFalse((self.tree / "unmanaged-drift").exists())
        self.set_pin(self.next_sha)
        self.apply()
        self.assertFalse((self.tree / "old-only").exists())
        self.assertTrue((self.tree / "new-only").exists())
        self.set_pin(self.first_sha)
        self.apply()
        self.assertEqual((self.tree / "skills/example/SKILL.md").read_text(encoding="utf-8"), "first revision\n")
        self.assertTrue((self.tree / "old-only").exists())
        self.assertFalse((self.tree / "new-only").exists())
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep")
        self.assertEqual(self.requests, ["/fixture/source/archive/" + sha + ".tar.gz" for sha in (self.first_sha, self.next_sha)])
        result = self.run_chezmoi("diff", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_other_host_and_site_aliases_need_no_symlink_privileges(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            data = b"portable skill content\n"
            skill = tarfile.TarInfo("source/skills/example/SKILL.md")
            skill.size = len(data)
            archive.addfile(skill, io.BytesIO(data))
            for alias, target in (
                (".agy/plugin.json", "../plugin.json"),
                (".agy/skills", "../skills"),
                (".claude/skills", "../skills"),
                ("CLAUDE.md", "AGENTS.md"),
                ("site/assets", "../assets"),
            ):
                link = tarfile.TarInfo("source/" + alias)
                link.type = tarfile.SYMTYPE
                link.linkname = target
                archive.addfile(link)
        self.payloads["/fixture/source/archive/" + self.first_sha + ".tar.gz"] = stream.getvalue()
        self.apply()
        self.assertEqual((self.tree / "skills/example/SKILL.md").read_bytes(), data)
        self.assertFalse((self.tree / ".agy").exists())
        self.assertFalse((self.tree / ".claude/skills").is_symlink())
        self.assertFalse((self.tree / "CLAUDE.md").is_symlink())
        self.assertFalse((self.tree / "site").exists())

    def test_archive_omits_unloaded_root_instructions_but_preserves_plugin_rules(self):
        self.add_archive(self.first_sha, {
            "AGENTS.md": "Contributor instructions, not plugin rules\n",
            "GEMINI.md": "Unsupported root plugin context\n",
            "rules/AGENTS.md": "Supported plugin rule\n",
            "skills/example/SKILL.md": "Runtime skill\n",
            "plugin.json": '{"name":"compound-engineering","version":"1.0.0"}\n',
        })
        # Reconciliation must also remove files left by an earlier installation.
        self.tree.mkdir(parents=True)
        for name in ("AGENTS.md", "GEMINI.md"):
            (self.tree / name).write_text("previous installation\n", encoding="utf-8")
        for _ in range(2):
            self.apply()
            for name in ("AGENTS.md", "GEMINI.md"):
                self.assertFalse((self.tree / name).exists(), name)
            self.assertEqual((self.tree / "rules/AGENTS.md").read_text(encoding="utf-8"),
                             "Supported plugin rule\n")
            self.assertTrue((self.tree / "skills/example/SKILL.md").is_file())
            self.assertTrue((self.tree / "plugin.json").is_file())

    def test_bootstrap_managed_does_not_install_or_write_configuration(self):
        shutil.copy2(self.repo / ".chezmoi-bootstrap.toml", self.config)
        result = self.run_chezmoi("managed", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def render_external(self, os_name, arch):
        template = (self.repo / "home/.chezmoitemplates/external-assets/harness-plugins.toml.tmpl").read_text(encoding="utf-8")
        wrapper = ('{{ template "external" (dict "chezmoi" (dict "os" '
                   + json.dumps(os_name) + ' "arch" ' + json.dumps(arch)
                   + ') "personalApps" .personalApps "harnessPlugins" .harnessPlugins "harnessPluginLocks" .harnessPluginLocks) }}'
                   + '{{ define "external" }}' + template + '{{ end }}')
        return self.run_chezmoi("execute-template", input=wrapper)

    def test_supported_platforms_render_sha_archive_only_in_dedicated_tree(self):
        for target in ("darwin-arm64", "linux-amd64", "linux-arm64", "windows-amd64", "windows-arm64"):
            with self.subTest(target=target):
                result = self.render_external(*target.split("-"))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                entries = tomllib.loads(result.stdout)
                self.assertEqual(list(entries), [".local/share/dotfiles/harness-plugins/compound-engineering"])
                entry = next(iter(entries.values()))
                self.assertEqual(entry["url"], "https://github.com/fixture/source/archive/" + self.first_sha + ".tar.gz")
                self.assertEqual(entry["type"], "archive")
                self.assertEqual(entry["stripComponents"], 1)
                self.assertTrue(entry["exact"])
        result = self.render_external("freebsd", "amd64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(tomllib.loads(result.stdout), {})
        result = self.render_external("darwin", "amd64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(tomllib.loads(result.stdout), {})
        result = self.render_external("linux", "arm")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(tomllib.loads(result.stdout), {})
        self.assertEqual(self.requests, [])

    def test_native_instructions_include_common_and_only_selected_harness(self):
        (self.source / ".chezmoitemplates/agent-instructions").write_text(
            'common instructions for {{ .chezmoi.destDir }}\n'
            '{{ if eq .harness "codex" }}codex only{{ end }}'
            '{{ if eq .harness "antigravity" }}antigravity only{{ end }}'
            '{{ if eq .harness "foreign" }}foreign only{{ end }}',
            encoding="utf-8",
        )
        self.apply()
        native = (self.home / ".gemini/GEMINI.md").read_text(encoding="utf-8")
        self.assertIn("common instructions for " + self.home.as_posix(), native.replace("\\", "/"))
        self.assertIn("antigravity only", native)
        self.assertNotIn("codex only", native)
        self.assertNotIn("foreign only", native)

    def test_retired_omp_files_survive_shared_asset_apply_without_reconciliation(self):
        retired = {
            ".local/bin/omp": b"retired executable\x00",
            ".local/bin/omp.exe": b"retired Windows executable\x00",
            ".omp/agent/config.yml": b"marketplace: {autoUpdate: notify}\n",
            ".omp/agent/config.yaml": b"other: configuration\n",
            ".omp/agent/AGENTS.md": b"personal instructions\n",
            ".omp/agent/auth.json": b"fixture-only credentials\n",
            ".omp/agent/agent.db": b"legacy session data\x00",
            ".omp/plugins/installed_plugins.json": b"personal plugin state\n",
            ".local/share/dotfiles/zsh/completions/_omp": b"retired completion\n",
        }
        for name, contents in retired.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        for _ in range(2):
            self.apply()
            self.assertEqual({name: (self.home / name).read_bytes() for name in retired}, retired)
            self.assertTrue((self.tree / "skills/example/SKILL.md").is_file())

    def test_fresh_apply_does_not_materialize_omp_state(self):
        self.apply()
        self.assertFalse((self.home / ".omp").exists())
        self.assertFalse((self.home / ".local/bin/omp").exists())
        self.assertFalse((self.home / ".local/bin/omp.exe").exists())

    def test_repository_inventory_and_asset_manifest_leave_omp_unmanaged(self):
        command = [self.chezmoi, "--config", str(self.config), "--source", str(self.repo),
                   "--destination", str(self.home), "--cache", str(self.root / "repository-cache"),
                   "--persistent-state", str(self.root / "repository-state.boltdb"), "--no-tty"]
        options = dict(env=self.env, capture_output=True, text=True, encoding="utf-8", timeout=60)
        managed = subprocess.run(command + ["managed", "--exclude=scripts"], **options)
        self.assertEqual(managed.returncode, 0, managed.stdout + managed.stderr)
        inventory = managed.stdout.replace("\\", "/").splitlines()
        self.assertFalse(any(path == ".omp" or path.startswith(".omp/") for path in inventory))
        manifest = subprocess.run(command + ["execute-template", '{{ includeTemplate "external-assets-manifest" . }}'],
                                  **options)
        self.assertEqual(manifest.returncode, 0, manifest.stdout + manifest.stderr)
        assets = tomllib.loads(manifest.stdout)
        self.assertNotIn(".local/bin/omp", assets)
        self.assertNotIn(".local/bin/omp.exe", assets)
        self.assertFalse(any(path == ".omp" or path.startswith(".omp/") for path in assets))



@unittest.skipUnless(os.environ.get("ANTIGRAVITY_TEST_BINARY"), "Set ANTIGRAVITY_TEST_BINARY to the locked native CLI")
class NativeAntigravityPluginsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running native plugin tests")
        scratch = tempfile.TemporaryDirectory(prefix="native plugins ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.home = self.root / "destination"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for directory in (".chezmoidata", ".chezmoitemplates", "private_dot_gemini"):
            shutil.copytree(self.repo / "home" / directory, self.source / directory)
        scripts = self.source / ".chezmoiscripts"
        scripts.mkdir()
        for name in ("run_after_20-antigravity-plugins.sh.tmpl", "run_after_20-antigravity-plugins.ps1.tmpl"):
            shutil.copy2(self.repo / "home/.chezmoiscripts" / name, scripts / name)
        self.config = self.root / "chezmoi.toml"
        config = ""
        if os.name == "nt":
            shell = shutil.which("pwsh") or str(
                Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            config = ('[interpreters.ps1]\ncommand = ' + json.dumps(shell)
                      + '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        self.config.write_text(config, encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"), "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"), "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"), "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
        })
        self.binary = self.home / ".local/share/dotfiles/antigravity/bin" / ("agy.exe" if os.name == "nt" else "agy")
        self.binary.parent.mkdir(parents=True)
        original = Path(os.environ["ANTIGRAVITY_TEST_BINARY"]).resolve()
        try:
            os.link(original, self.binary)
        except OSError:
            shutil.copy2(original, self.binary)
        self.plugin = self.home / ".local/share/dotfiles/harness-plugins/compound-engineering"
        self.make_plugin(self.plugin, "compound-engineering")
        self.native_settings = self.home / ".gemini/config/config.json"

    def make_plugin(self, directory, name):
        skill = directory / "skills" / (name + "-example") / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\nname: " + name + "-example\ndescription: Local test skill\n---\nTest skill.\n", encoding="utf-8")
        (directory / "plugin.json").write_text(json.dumps({
            "name": name, "version": "1.0.0", "description": "Local native integration fixture",
        }), encoding="utf-8")

    def native(self, *args):
        result = subprocess.run([str(self.binary), "plugin", *args], env=self.env,
                                cwd=self.root, capture_output=True, text=True,
                                encoding="utf-8", errors="backslashreplace", timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def apply(self, check=True):
        result = subprocess.run([
            self.chezmoi, "--config", str(self.config), "--source", str(self.source),
            "--destination", str(self.home), "--cache", str(self.root / "cache"),
            "--persistent-state", str(self.root / "chezmoi-state.boltdb"), "--no-tty",
            "apply", "--force",
        ], env=self.env, cwd=self.root, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_reapply_repairs_enabled_state_and_preserves_unrelated_plugins_and_settings(self):
        unrelated = self.root / "unrelated"
        self.make_plugin(unrelated, "unrelated")
        self.native("install", str(unrelated))
        self.native("disable", "unrelated")
        config = json.loads(self.native_settings.read_text(encoding="utf-8"))
        config["unrelatedSetting"] = {"nested": [1, "keep", True]}
        self.native_settings.write_text(json.dumps(config), encoding="utf-8")
        self.apply()
        self.native("disable", "compound-engineering")
        self.apply()
        self.apply()
        installed = json.loads(self.native("list", "--json").stdout)
        managed = [plugin for plugin in installed if plugin["name"] == "compound-engineering"]
        self.assertEqual(len(managed), 1)
        self.assertTrue(managed[0]["enabled"])
        self.assertIn("compound-engineering-example", managed[0]["skills"])
        sibling = [plugin for plugin in installed if plugin["name"] == "unrelated"]
        self.assertEqual(len(sibling), 1)
        self.assertFalse(sibling[0]["enabled"])
        state = json.loads(self.native_settings.read_text(encoding="utf-8"))
        self.assertEqual(state["unrelatedSetting"], config["unrelatedSetting"])
        self.native("validate", managed[0]["path"])

    def test_malformed_native_state_fails_apply_without_replacement(self):
        self.native_settings.parent.mkdir(parents=True)
        original = b'{"plugins": [unterminated\n'
        for name in ("config.json", "import_manifest.json"):
            with self.subTest(filename=name):
                path = self.native_settings.with_name(name)
                path.write_bytes(original)
                result = self.apply(check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_bytes(), original)
                path.unlink()


if __name__ == "__main__":
    unittest.main()
