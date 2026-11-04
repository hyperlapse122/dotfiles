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
        for directory in (".chezmoidata", ".chezmoitemplates", "private_dot_omp"):
            shutil.copytree(self.repo / "home" / directory, self.source / directory)
        shutil.copy2(self.repo / "home/.chezmoiignore", self.source / ".chezmoiignore")
        (self.source / ".chezmoiexternals").mkdir()
        self.external = self.source / ".chezmoiexternals/harness-plugins.toml.tmpl"
        shutil.copy2(self.repo / "home/.chezmoiexternals/harness-plugins.toml.tmpl", self.external)
        (self.source / ".chezmoiscripts").mkdir()
        for name in ("run_onchange_after_20-harness-plugins.ps1.tmpl", "run_onchange_after_20-harness-plugins.sh.tmpl"):
            shutil.copy2(self.repo / "home/.chezmoiscripts" / name, self.source / ".chezmoiscripts" / name)
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
        self.agent = self.home / ".omp/agent"
        self.yml = self.agent / "config.yml"
        self.yaml = self.agent / "config.yaml"

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
        return subprocess.run(
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

    def read_yaml(self, path):
        result = self.run_chezmoi("execute-template", "{{ include " + json.dumps(path.as_posix()) + " | fromYaml | toJson }}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

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

    def test_configuration_and_parents_remain_owner_only(self):
        self.config.write_text("umask = 0o022\n", encoding="utf-8")
        self.agent.mkdir(parents=True)
        for directory in (self.agent.parent, self.agent):
            directory.chmod(0o700)
        for path in (self.yml, self.yaml):
            with self.subTest(filename=path.name):
                path.write_text("auth: {broker: {token: fixture-only}}\n", encoding="utf-8")
                path.chmod(0o600)
                for _ in range(2):
                    self.apply()
                    result = self.run_chezmoi("dump", "--format=json", "--parent-dirs", str(path))
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    state = json.loads(result.stdout)
                    for target, mode in ((".omp", 0o700), (".omp/agent", 0o700),
                                         (".omp/agent/" + path.name, 0o600)):
                        self.assertEqual(state[target]["perm"], mode)
                        if os.name != "nt":
                            self.assertEqual((self.home / target).stat().st_mode & 0o777, mode)
                path.unlink()

    def test_effective_yaml_preserves_mutable_values_and_has_no_shadow(self):
        self.agent.mkdir(parents=True)
        self.yaml.write_text("marketplace:\n  autoUpdate: auto\n  sibling: keep\nnested:\n  array: [one, 2, true]\n", encoding="utf-8")
        self.apply()
        self.assertFalse(self.yml.exists())
        self.assertEqual(self.read_yaml(self.yaml), {
            "marketplace": {"autoUpdate": "off", "sibling": "keep"},
            "nested": {"array": ["one", 2, True]},
        })
        self.yaml.write_text("marketplace:\n  autoUpdate: notify\n  sibling: changed\nnested:\n  array: [new, 3, false]\nextra: {value: user-edit}\n", encoding="utf-8")
        self.apply()
        self.assertEqual(self.read_yaml(self.yaml), {
            "marketplace": {"autoUpdate": "off", "sibling": "changed"},
            "nested": {"array": ["new", 3, False]}, "extra": {"value": "user-edit"},
        })
        before = self.yaml.read_bytes()
        self.apply()
        self.assertEqual(self.yaml.read_bytes(), before)
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

    def test_existing_yml_wins_and_yaml_is_untouched(self):
        self.agent.mkdir(parents=True)
        self.yml.write_text("marketplace: {autoUpdate: auto}\nkeep: yml\n", encoding="utf-8")
        original = b"keep: yaml\nmarketplace: {autoUpdate: notify}\n"
        self.yaml.write_bytes(original)
        self.apply()
        self.assertEqual(self.read_yaml(self.yml), {"marketplace": {"autoUpdate": "off"}, "keep": "yml"})
        self.assertEqual(self.yaml.read_bytes(), original)

    def test_missing_and_empty_configuration_initialize_minimally(self):
        self.apply()
        self.assertEqual(self.read_yaml(self.yml), {"marketplace": {"autoUpdate": "off"}})
        self.assertFalse(self.yaml.exists())
        self.yml.write_bytes(b"")
        self.apply()
        self.assertEqual(self.read_yaml(self.yml), {"marketplace": {"autoUpdate": "off"}})

    def test_malformed_yaml_fails_without_replacement(self):
        self.agent.mkdir(parents=True)
        for path in (self.yml, self.yaml):
            with self.subTest(filename=path.name):
                original = b"marketplace: [unterminated\nkeep: untouched\n"
                path.write_bytes(original)
                result = self.run_chezmoi("apply", "--force", "--exclude=scripts")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_bytes(), original)
                self.assertFalse((self.yaml if path == self.yml else self.yml).exists())
                path.unlink()

    def test_legacy_pending_migration_is_not_shadowed(self):
        self.agent.mkdir(parents=True)
        for filename in ("settings.json", "agent.db"):
            with self.subTest(filename=filename):
                legacy = self.agent / filename
                original = b"legacy state must remain untouched\x00"
                legacy.write_bytes(original)
                result = self.run_chezmoi("apply", "--force", "--exclude=scripts")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("migration", result.stderr.lower())
                self.assertEqual(legacy.read_bytes(), original)
                self.assertFalse(self.yml.exists())
                self.assertFalse(self.yaml.exists())
                legacy.unlink()

    def test_bootstrap_managed_does_not_install_or_write_configuration(self):
        shutil.copy2(self.repo / ".chezmoi-bootstrap.toml", self.config)
        result = self.run_chezmoi("managed", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.home.iterdir()), [])

    def render_external(self, os_name, arch):
        template = (self.repo / "home/.chezmoiexternals/harness-plugins.toml.tmpl").read_text(encoding="utf-8")
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


if __name__ == "__main__":
    unittest.main()
