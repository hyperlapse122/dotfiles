"""Pinned writing skills reach every shared skill root as plain single-skill copies."""

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


REPO = Path(__file__).resolve().parents[1]
TEMPLATE = ".chezmoitemplates/external-assets/harness-skills.toml.tmpl"
REPOSITORY = "DaleSeo/korean-skills"
SKILLS = ("grammar-checker", "humanizer", "style-guide")
# Each shared root and the harnesses that read it.
LOCATIONS = {
    ".agents/skills": ("codex", "pi", "omp", "grok"),
    ".claude/skills": ("claude",),
    ".gemini/config/skills": ("antigravity",),
}
TARGETS = ("darwin-arm64", "linux-amd64", "linux-arm64", "windows-amd64", "windows-arm64")
SKILL_FILES = ("SKILL.md", "references/rules.md", "examples/before.md")


def roots(locations):
    return {location + "/" + skill for location in locations for skill in SKILLS}


class HarnessSkillsTest(unittest.TestCase):
    def setUp(self):
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running harness skill tests")
        self.scratch = tempfile.TemporaryDirectory(prefix="harness skills ' ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "user home"
        self.home.mkdir()
        self.source = self.root / "source"
        for directory in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(REPO / "home" / directory, self.source / directory)
        copy_asset_templates(self.source, ("harness-skills",))
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("", encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "USERPROFILE": str(self.home),
            "APPDATA": str(self.root / "config"),
            "LOCALAPPDATA": str(self.root / "local"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CONFIG_DIRS": str(self.root / "system config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_STATE_HOME": str(self.root / "state"),
        })
        self.sha = "1" * 40
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
        # Only redirect archive transport; pin selection and extraction stay native.
        external = self.source / TEMPLATE
        external.write_text(external.read_text(encoding="utf-8").replace(
            "https://github.com", "http://127.0.0.1:" + str(self.server.server_port)), encoding="utf-8")
        self.add_archive(self.sha)
        self.set_pin({"tag": "v1.0.0", "commit": self.sha})

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def add_archive(self, sha):
        """Mirror the upstream layout, including the root CLAUDE.md symlink."""
        top = "korean-skills-" + sha
        files = {"AGENTS.md": "repository rules\n", "README.md": "readme\n", "README_EN.md": "readme\n",
                 "LICENSE": "license\n", ".claude-plugin/plugin.json": "{}\n",
                 ".claude-plugin/marketplace.json": "{}\n", ".github/workflows/ci.yml": "ci\n"}
        for skill in SKILLS:
            for name in SKILL_FILES:
                files["skills/" + skill + "/" + name] = skill + " " + name + " at " + sha + "\n"
        directories = {""}
        for name in files:
            parts = name.split("/")[:-1]
            directories.update("/".join(parts[:index]) for index in range(1, len(parts) + 1))
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for directory in sorted(directories):
                info = tarfile.TarInfo(top + "/" + directory if directory else top)
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                archive.addfile(info)
            for name, text in files.items():
                data = text.encode("utf-8")
                info = tarfile.TarInfo(top + "/" + name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            link = tarfile.TarInfo(top + "/CLAUDE.md")
            link.type, link.linkname = tarfile.SYMTYPE, "AGENTS.md"
            archive.addfile(link)
        self.payloads["/" + REPOSITORY + "/archive/" + sha + ".tar.gz"] = stream.getvalue()

    def set_pin(self, pin):
        lock_path = self.source / ".chezmoidata/harness-plugin-lock.json"
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        lock["harnessSkillLocks"] = {"korean-skills": pin}
        lock_path.write_text(json.dumps(lock), encoding="utf-8")

    def run_chezmoi(self, *args, input=None):
        return run_with_assets(
            [self.chezmoi, "--config", str(self.config), "--source", str(self.source),
             "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
             "--persistent-state", str(self.root / "chezmoi-state.boltdb"), *args],
            env=self.env, input=input, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=120,
        )

    def apply(self):
        result = self.run_chezmoi("apply", "--force", "--exclude=scripts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def render(self, target, apps=None):
        os_name, arch = target.split("-")
        template = (REPO / "home" / TEMPLATE).read_text(encoding="utf-8")
        personal_apps = ".personalApps" if apps is None else "(fromJson " + json.dumps(json.dumps(apps)) + ")"
        wrapper = ('{{ template "external" (dict "chezmoi" (dict "os" ' + json.dumps(os_name)
                   + ' "arch" ' + json.dumps(arch) + ') "personalApps" ' + personal_apps
                   + ' "harnessSkills" .harnessSkills "harnessSkillLocks" .harnessSkillLocks) }}'
                   + '{{ define "external" }}' + template + '{{ end }}')
        return self.run_chezmoi("execute-template", input=wrapper)

    def installed_files(self):
        return {path.relative_to(self.home).as_posix(): path.read_text(encoding="utf-8")
                for path in self.home.rglob("*") if path.is_file() or path.is_symlink()}

    def test_targeted_platforms_render_one_exact_pinned_root_per_skill_and_location(self):
        for target in TARGETS:
            with self.subTest(target=target):
                result = self.render(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                entries = tomllib.loads(result.stdout)
                self.assertEqual(set(entries), roots(LOCATIONS))
                for path, entry in entries.items():
                    skill = path.rsplit("/", 1)[1]
                    self.assertEqual(entry["type"], "archive")
                    self.assertEqual(entry["url"], "https://github.com/" + REPOSITORY + "/archive/" + self.sha + ".tar.gz")
                    self.assertEqual(entry["refreshPeriod"], "0")
                    self.assertTrue(entry["exact"])
                    # Archive top directory, then skills/<name>, so SKILL.md lands in the root.
                    self.assertEqual(entry["stripComponents"], 3)
                    self.assertEqual(entry["include"], ["*/skills/" + skill + "/**"])
        for target in ("freebsd-amd64", "darwin-amd64", "linux-arm"):
            with self.subTest(target=target):
                result = self.render(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(tomllib.loads(result.stdout), {})
        self.assertEqual(self.requests, [])

    def test_location_renders_only_when_one_of_its_harnesses_is_targeted(self):
        apps = json.loads((REPO / "home/.chezmoidata/personal-apps.json").read_text(encoding="utf-8"))["personalApps"]
        for location, readers in LOCATIONS.items():
            for app in readers:
                with self.subTest(app=app):
                    result = self.render("linux-amd64", {app: apps[app]})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(set(tomllib.loads(result.stdout)), roots([location]))

    def test_pin_without_full_commit_fails_rendering(self):
        for pin in ({"tag": "v1.0.0"}, {"tag": "v1.0.0", "commit": self.sha[:7]}):
            with self.subTest(pin=pin):
                self.set_pin(pin)
                result = self.render("linux-amd64")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("korean-skills", result.stderr)

    def test_real_manifest_declares_every_skill_root_as_exact_directory(self):
        context = ('{{ $ctx := . | setValueAtPath "chezmoi.os" "linux" | setValueAtPath "chezmoi.arch" "amd64" }}'
                   '{{ includeTemplate "external-asset-roots" $ctx }}')
        result = subprocess.run([self.chezmoi, "--source", str(REPO), "--config", str(self.config),
                                 "execute-template", context], env=self.env, capture_output=True,
                                text=True, encoding="utf-8", timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        declared = set(result.stdout.splitlines())
        for path in roots(LOCATIONS):
            self.assertIn(path + "\tdirectory\ttrue", declared)

    def test_apply_places_only_each_skill_subtree_directly_in_every_root(self):
        self.apply()
        expected = {path + "/" + name: path.rsplit("/", 1)[1] + " " + name + " at " + self.sha + "\n"
                    for path in roots(LOCATIONS) for name in SKILL_FILES}
        # Nothing from the repository root (.claude-plugin, CLAUDE.md, README files) is installed.
        self.assertEqual(self.installed_files(), expected)
        # All nine roots share one pinned archive URL, so it is fetched once.
        self.assertEqual(self.requests, ["/" + REPOSITORY + "/archive/" + self.sha + ".tar.gz"])

    def test_reapply_repairs_managed_skills_and_keeps_unrelated_sibling_skills(self):
        siblings = {location + "/owner-skill/SKILL.md": "owner skill\n" for location in LOCATIONS}
        for relative, text in siblings.items():
            (self.home / relative).parent.mkdir(parents=True)
            (self.home / relative).write_text(text, encoding="utf-8")
        self.apply()
        stale = self.home / ".agents/skills/humanizer/stale.md"
        stale.write_text("stale\n", encoding="utf-8")
        drifted = self.home / ".agents/skills/style-guide/SKILL.md"
        drifted.write_text("drift\n", encoding="utf-8")
        self.apply()
        self.assertFalse(stale.exists())
        self.assertEqual(drifted.read_text(encoding="utf-8"), "style-guide SKILL.md at " + self.sha + "\n")
        for relative, text in siblings.items():
            self.assertEqual((self.home / relative).read_text(encoding="utf-8"), text)

    def test_existing_directory_at_managed_skill_path_is_replaced_by_pinned_copy(self):
        existing = self.home / ".claude/skills/humanizer"
        (existing / "references").mkdir(parents=True)
        (existing / "SKILL.md").write_text("owner humanizer\n", encoding="utf-8")
        (existing / "references/owner-notes.md").write_text("owner notes\n", encoding="utf-8")
        self.apply()
        self.assertEqual(sorted(path.relative_to(existing).as_posix() for path in existing.rglob("*")),
                         ["SKILL.md", "examples", "examples/before.md", "references", "references/rules.md"])
        self.assertEqual((existing / "SKILL.md").read_text(encoding="utf-8"), "humanizer SKILL.md at " + self.sha + "\n")


if __name__ == "__main__":
    unittest.main()
