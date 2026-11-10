"""Exercise restoration through the installed reconciler and pinned OMP CLI."""

import copy
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import tempfile
import unittest

import xxhash
import yaml


RECONCILER, OMP = sys.argv[1:3]
del sys.argv[1:3]
ACTIVATIONS = json.loads(Path(sys.argv.pop(1)).read_text()) if len(sys.argv) > 1 else []
HELPERS = json.loads(Path(sys.argv.pop(1)).read_text()) if len(sys.argv) > 1 else {}
OPENROUTER = json.loads(Path(sys.argv.pop(1)).read_text()) if len(sys.argv) > 1 else {"data": []}
SYNTHETIC = json.loads(Path(sys.argv.pop(1)).read_text()) if len(sys.argv) > 1 else {"data": []}


class Restoration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.agent = self.home / ".omp/agent"
        self.agent.mkdir(parents=True)
        self.document = {
            "config.yml": {
                "memory": {"backend": "off"},
                "startup": {"checkUpdate": False},
                "marketplace": {"autoUpdate": "off"},
            },
            "models.yml": {"providers": {}},
            "mcp.json": {"mcpServers": {}},
        }
        self.manifest = self.home / "declared.json"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("OMP_", "PI_", "XDG_"))}
        self.env["HOME"] = str(self.home)

    def apply(self, *args, success=True):
        paths = {}
        for i, (name, value) in enumerate(self.document.items()):
            path = self.home / f"document-{i}.json"
            path.write_text(json.dumps(value))
            paths[name] = str(path)
        self.manifest.write_text(json.dumps(paths))
        result = subprocess.run(
            [RECONCILER, "--agent-dir", str(self.agent), "--declared", str(self.manifest),
             "--lock-timeout", "0.1", *args],
            env=self.env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode == 0, success, result.stderr)
        self.assertNotIn("FAKE_SECRET", result.stdout + result.stderr)
        return result

    def omp(self, *args, cwd=None):
        return subprocess.run([OMP, *args], cwd=cwd or self.home, env=self.env,
                              capture_output=True, text=True, timeout=20)

    def read(self, name="config.yml"):
        return yaml.safe_load((self.agent / name).read_text())

    def test_complete_documents_restore_drift_and_preserve_state(self):
        sentinels = [".omp/agent/agent.db", ".omp/agent/auth.json", ".omp/agent/sessions/old.jsonl",
                     ".cache/omp/data", ".local/state/omp/old", ".local/share/omp/agent.db",
                     ".omp/profiles/work/agent/config.yml", "project/.omp/config.yml"]
        for name in sentinels:
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"FAKE_SECRET state sentinel\x00")
        self.apply()
        changed = self.read()
        changed["memory"]["backend"] = "local"
        changed["newGlobalKey"] = {"enabled": True}
        changed["auth"] = {"accountPolicies": {"fake": {"enabled": False}}}
        (self.agent / "config.yml").write_text(yaml.safe_dump(changed))
        (self.agent / "models.yml").write_text("providers: {extra: {models: []}}")
        self.apply()
        for name, expected in self.document.items():
            self.assertEqual(self.read(name), expected)
            self.assertEqual(stat.S_IMODE((self.agent / name).stat().st_mode), 0o600)
        before = (self.agent / "config.yml").stat().st_ino
        self.apply()
        self.assertEqual((self.agent / "config.yml").stat().st_ino, before)
        for name in sentinels:
            self.assertEqual((self.home / name).read_bytes(), b"FAKE_SECRET state sentinel\x00")

    def test_preflight_refusals_leave_every_document_untouched(self):
        invalid = ["bad: [FAKE_SECRET", "[FAKE_SECRET]", "memory: off\nmemory: local",
                   "auth: {broker: {token: FAKE_SECRET}}"]
        for content in invalid:
            with self.subTest(content=content):
                (self.agent / "config.yml").write_text(content)
                (self.agent / "models.yml").write_text("providers: {drift: {}}")
                before = {p: p.read_bytes() for p in self.agent.iterdir() if p.is_file()}
                self.apply(success=False)
                self.assertEqual({p: p.read_bytes() for p in before}, before)
                self.assertFalse((self.agent / "mcp.json").exists())

    def test_credential_binding_requires_the_same_declared_identity(self):
        self.document["config.yml"]["auth"] = {"broker": {"url": "https://broker.example"}}
        old = copy.deepcopy(self.document["config.yml"])
        old["auth"]["broker"]["token"] = "FAKE_SECRET"
        (self.agent / "config.yml").write_text(yaml.safe_dump(old))
        self.apply()
        self.assertEqual(self.read(), old)
        self.document["config.yml"]["auth"]["broker"]["url"] = "https://other.example"
        self.apply(success=False)
        self.assertEqual(self.read(), old)

    def test_mcp_oauth_survives_only_for_same_server(self):
        server = {"type": "http", "url": "https://tools.example/mcp"}
        self.document["mcp.json"]["mcpServers"]["tools"] = server
        old = {**server, "auth": {"type": "oauth", "credentialId": "FAKE_SECRET"}}
        (self.agent / "mcp.json").write_text(json.dumps({"mcpServers": {"tools": old}}))
        self.apply()
        self.assertEqual(self.read("mcp.json")["mcpServers"]["tools"], old)
        server["url"] = "https://other.example/mcp"
        self.apply(success=False)
        self.assertEqual(self.read("mcp.json")["mcpServers"]["tools"], old)

    def test_compatibility_names_and_physical_main_settings_target(self):
        target = self.agent / "config.yaml"
        target.write_text("startup: {checkUpdate: true}")
        self.apply()
        self.assertFalse((self.agent / "config.yml").exists())
        self.assertEqual(yaml.safe_load(target.read_text()), self.document["config.yml"])
        link = self.agent / "config.yml"
        link.symlink_to("config.yaml")
        self.apply()
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.omp("config", "get", "memory.backend").stdout.strip(), "off")

    def test_legacy_credentials_and_model_credentials_fail_before_mutation(self):
        for filename, value in [("settings.json", {"auth": {"broker": {"token": "FAKE_SECRET"}}}),
                                ("models.json", {"providers": {"private": {"apiKey": "FAKE_SECRET"}}})]:
            with self.subTest(filename=filename):
                path = self.agent / filename
                path.write_text(json.dumps(value))
                self.apply(success=False)
                self.assertEqual(json.loads(path.read_text()), value)
                self.assertFalse((self.agent / "config.yml").exists())
                path.unlink()

    def test_managed_provider_helpers_upgrade_and_rollback_without_a_ledger(self):
        self.assertTrue(HELPERS, "no immutable helper generations to verify")
        for generation in ("previous", "current", "previous"):
            self.document["models.yml"] = {"providers": {
                name: {"baseUrl": endpoint, "apiKey": f"!{HELPERS[generation]}/bin/omp-{name}-key",
                       "models": [], "modelOverrides": {generation: {"name": generation}}}
                for name, endpoint in (("synthetic", "https://api.synthetic.new/openai/v1"),
                                       ("openrouter", "https://openrouter.ai/api/v1"))
            }}
            self.apply()
            self.assertEqual(self.read("models.yml"), self.document["models.yml"])

        declared = copy.deepcopy(self.document["models.yml"])
        for name, provider in self.document["models.yml"]["providers"].items():
            provider["apiKey"] = f"!{HELPERS['current']}/bin/omp-{name}-key"
        bindings = ["FAKE_SECRET", "!printf FAKE_SECRET",
                    f"!{HELPERS['unknown']}/bin/omp-synthetic-key",
                    f"!{HELPERS['current']}/bin/omp-openrouter-key",
                    f"!{HELPERS['current']}/bin/omp-synthetic-key --extra"]
        cases = [{"apiKey": value} for value in bindings]
        cases += [{"baseUrl": "https://other.example"}, {"api": "different-api"}]
        # Even a recognized helper cannot hide an unrelated credential change.
        cases += [{"headers": {"Authorization": "FAKE_SECRET"}}]
        for changes in cases:
            with self.subTest(changes=changes):
                old = copy.deepcopy(declared)
                old["providers"]["synthetic"].update(changes)
                (self.agent / "models.yml").write_text(json.dumps(old))
                (self.agent / "config.yml").write_text("startup: {checkUpdate: true}")
                before = {name: (self.agent / name).read_bytes() for name in self.document}
                self.apply(success=False)
                self.assertEqual({name: (self.agent / name).read_bytes() for name in before}, before)

    def test_settings_symlink_cannot_replace_profile_or_auth_state(self):
        profile = self.home / ".omp/profiles/work/agent/config.yml"
        profile.parent.mkdir(parents=True)
        state = self.agent / "auth.json"
        for target in (profile, state):
            with self.subTest(target=target):
                for name in ("config.yml", "models.yml", "mcp.json"):
                    (self.agent / name).unlink(missing_ok=True)
                target.write_text('{"preserved": "FAKE_SECRET"}')
                link = self.agent / "config.yml"
                link.symlink_to(target)
                self.apply(success=False)
                self.assertEqual(target.read_text(), '{"preserved": "FAKE_SECRET"}')
                self.assertTrue(link.is_symlink())
                self.assertFalse((self.agent / "mcp.json").exists())
                link.unlink()

    def test_dry_run_has_no_filesystem_effect(self):
        (self.agent / "config.yml").write_text("startup: {checkUpdate: true}")
        before = (self.agent / "config.yml").read_bytes()
        self.apply("--dry-run")
        self.assertEqual((self.agent / "config.yml").read_bytes(), before)
        self.assertFalse((self.agent / "models.yml").exists())
        for path in self.agent.iterdir():
            path.unlink()
        self.agent.rmdir()
        self.apply("--dry-run")
        self.assertFalse(self.agent.exists())

    def test_settings_remain_writable_and_project_profiles_remain_effective(self):
        self.apply()
        result = self.omp("config", "set", "memory.backend", "local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()["memory"]["backend"], "local")
        self.apply()
        self.assertEqual(self.read()["memory"]["backend"], "off")
        project = self.home / "project/.omp"
        project.mkdir(parents=True)
        (project / "config.yml").write_text("memory: {backend: local}")
        result = self.omp("config", "get", "memory.backend", cwd=project.parent)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "local"), result.stderr)
        profile = self.home / ".omp/profiles/work/agent"
        profile.mkdir(parents=True)
        (profile / "config.yml").write_text("memory: {backend: mnemopi}")
        result = self.omp("--profile", "work", "config", "get", "memory.backend")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "mnemopi"), result.stderr)

    def test_real_omp_and_reconciler_contend_on_the_same_lock(self):
        self.apply()
        target = self.agent / "config.yml"
        # The name and seeds are the pinned native contract, independently
        # exercised by an actual OMP settings write while we own its lease.
        if sys.platform == "linux":
            lease = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            lock_path = str(target.resolve()) + ".lock"
            high = xxhash.xxh64(lock_path.encode(), seed=0x4F4D502D4C4F434B).hexdigest()
            low = xxhash.xxh64(lock_path.encode(), seed=0x50492D46494C454C).hexdigest()
            lease.bind("\0omp-file-lock-" + high + low)
        else:
            import fcntl
            lease = open(str(target.resolve()) + ".lock", "a+b")
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            self.apply(success=False)
            result = self.omp("config", "set", "memory.backend", "local")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("lock", result.stderr.lower())
            self.assertEqual(self.read(), self.document["config.yml"])
        finally:
            lease.close()
        self.apply()


class Activation(unittest.TestCase):
    def test_materialized_home_steps_restore_and_propagate_failures(self):
        self.assertTrue(ACTIVATIONS, "no materialized home activations to verify")
        for entry in ACTIVATIONS:
            with self.subTest(host=entry["name"]), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary)
                script = Path(entry["activate"]).read_text()
                match = re.search(r'_iNote "Activating %s" "ompSettings"\n(.*?)(?=\n_iNote|\Z)',
                                  script, flags=re.S)
                self.assertIsNotNone(match, "generation has no ompSettings step")
                block = match.group(1)
                self.assertIn(entry["home"], block)
                block = block.replace(entry["home"], str(home))
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(("OMP_", "PI_", "XDG_"))}
                env["HOME"] = str(home)
                env.pop("DRY_RUN", None)
                target = home / ".omp/agent/config.yml"
                skills = {}
                for directory, name in (("managed-skills", "old-generated"),
                                        ("skills", "authored")):
                    skill = target.parent / directory / name / "SKILL.md"
                    skill.parent.mkdir(parents=True)
                    skill.write_text(f"---\nname: {name}\ndescription: Policy fixture\n---\nKeep this skill.\n")
                    skills[skill] = skill.read_bytes()

                def discovered_skills():
                    result = subprocess.run([OMP, "skill", "list", str(home), "--json"],
                                            cwd=home, env=env, capture_output=True,
                                            text=True, timeout=20)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    return {skill["name"] for skill in json.loads(result.stdout)["skills"]}

                def activate(success=True):
                    result = subprocess.run(["bash", "-euo", "pipefail", "-c", block],
                                            env=env, capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode == 0, success, result.stderr)

                expected_patterns = [
                    *(f"synthetic/{row['id']}" for row in SYNTHETIC["data"]),
                    *(f"openrouter/{row['id']}" for row in OPENROUTER["data"]
                      if row["id"].startswith("openrouter/") and row["id"] != "openrouter/bodybuilder"),
                ]
                target.write_text(
                    "autolearn: {enabled: true}\ndisabledProviders: []\n"
                    "tui: {mouse: true}\nenabledModels: ['openai-codex/*']\n"
                )
                self.assertIn("old-generated", discovered_skills())
                activate()
                value = yaml.safe_load(target.read_text())
                self.assertEqual(value["memory"]["backend"], "off")
                self.assertIs(value["autolearn"]["enabled"], False)
                self.assertIs(value["startup"]["checkUpdate"], False)
                self.assertEqual(value["marketplace"]["autoUpdate"], "off")
                self.assertIs(value["tui"]["mouse"], False)
                self.assertEqual(value["enabledModels"], expected_patterns)
                self.assertEqual(value["disabledProviders"], ["omp-managed", "openai-codex", "google-antigravity"])
                expected_roles = {
                    "default": "synthetic/hf:moonshotai/Kimi-K3",
                    "smol": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "slow": "synthetic/hf:moonshotai/Kimi-K3:high",
                    "plan": "synthetic/hf:moonshotai/Kimi-K3:high",
                    "task": "synthetic/hf:zai-org/GLM-5.3:high",
                    "commit": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "web": "web/synthetic",
                }
                expected_overrides = {
                    "sonic": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "scout": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "seance": "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash:low",
                    "task": "synthetic/hf:zai-org/GLM-5.3:high",
                    "reviewer": "synthetic/hf:zai-org/GLM-5.3:high",
                    "security-reviewer": "synthetic/hf:zai-org/GLM-5.3:high",
                    "architect": "synthetic/hf:moonshotai/Kimi-K3:high",
                }
                for key, expected in (("modelRoles", expected_roles),
                                      ("task.agentModelOverrides", expected_overrides),
                                      ("defaultThinkingLevel", "high"),
                                      ("github.enabled", "true"),
                                      ("task.enableEffort", "true"),
                                      ("task.maxEffort", "high"),
                                      ("tui.mouse", "false"),
                                      ("enabledModels", expected_patterns),
                                      ("disabledProviders", ["omp-managed", "openai-codex", "google-antigravity"])):
                    result = subprocess.run([OMP, "config", "get", key], cwd=home, env=env,
                                            capture_output=True, text=True, timeout=20)
                    actual = json.loads(result.stdout) if key in ("modelRoles", "task.agentModelOverrides", "enabledModels", "disabledProviders") else result.stdout.strip()
                    self.assertEqual((result.returncode, actual), (0, expected), result.stderr)
                self.assertEqual(discovered_skills(), {"authored"})
                for skill, contents in skills.items():
                    self.assertEqual(skill.read_bytes(), contents)
                # The fff MCP server starts by its store path, since T3 Code and
                # GUI sessions do not inherit the login PATH.
                mcp = target.parent / "mcp.json"
                servers = json.loads(mcp.read_text())["mcpServers"]
                self.assertEqual(set(servers), {"fff"})
                fff = servers["fff"]
                self.assertTrue(fff["command"].startswith("/nix/store/")
                                and fff["command"].endswith("/bin/fff-mcp"), fff)
                self.assertTrue(os.access(fff["command"], os.X_OK), fff)
                self.assertEqual(fff["args"], ["--no-update-check"])
                servers["fff"]["auth"] = {"token": "FAKE_TOKEN"}
                mcp.write_text(json.dumps({"mcpServers": servers}))
                activate()
                self.assertEqual(json.loads(mcp.read_text())["mcpServers"]["fff"]["auth"],
                                 {"token": "FAKE_TOKEN"})
                target.write_text("memory: {backend: local}\nnewSetting: true\n")
                activate()
                self.assertEqual(yaml.safe_load(target.read_text()), value)
                target.write_text("invalid: [FAKE_SECRET")
                activate(success=False)
                self.assertEqual(target.read_text(), "invalid: [FAKE_SECRET")
                env["DRY_RUN"] = "1"
                target.write_text("memory: {backend: local}")
                activate()
                self.assertEqual(target.read_text(), "memory: {backend: local}")


if __name__ == "__main__":
    unittest.main()
