import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class T3CodeSettingsTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        self.chezmoi = shutil.which("chezmoi")
        self.assertIsNotNone(self.chezmoi, "Install chezmoi before running T3 Code settings tests")
        scratch = tempfile.TemporaryDirectory(prefix="t3 settings ' ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.home = self.root / "user's home"
        self.home.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copytree(self.repo / "home/private_dot_t3", self.source / "private_dot_t3")
        (self.source / ".chezmoitemplates").mkdir()
        for path in (self.repo / "home/.chezmoitemplates").glob("t3-code-*"):
            shutil.copy2(path, self.source / ".chezmoitemplates" / path.name)
        self.preferences = json.loads((self.repo / "home/.chezmoidata/t3-code.json").read_text(
            encoding="utf-8"))["t3CodePreferences"]
        self.write_preferences(self.preferences["server"], self.preferences["client"])
        self.config = self.root / "chezmoi.toml"
        self.config.write_text("umask = 0o022\n", encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.upper().startswith("CHEZMOI_")}
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
        self.settings = self.home / ".t3/userdata/settings.json"

    def chez(self, *args, input=None, check=True):
        result = subprocess.run(
            [self.chezmoi, "--config", str(self.config), "--source", str(self.source),
             "--destination", str(self.home), "--cache", str(self.root / "chezmoi-cache"),
             "--persistent-state", str(self.root / "chezmoi-state.boltdb"), "--no-tty", *args],
            env=self.env, input=input, capture_output=True, text=True,
            encoding="utf-8", errors="backslashreplace", timeout=60,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def apply(self, check=True):
        return self.chez("apply", "--force", "--exclude=scripts", check=check)

    def write_settings(self, value):
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps(value), encoding="utf-8")

    def read_settings(self):
        return json.loads(self.settings.read_text(encoding="utf-8"))

    def expected_provider(self, os_name=None):
        if os_name is None:
            os_name = self.chez("execute-template", "{{ .chezmoi.os }}").stdout
        executable = "omp.exe" if os_name == "windows" else "omp"
        return {
            "driver": "acpRegistry", "enabled": True,
            "displayName": "oh-my-pi", "accentColor": "#f84fcc",
            "config": {"enabled": True, "source": "local",
                       "commandPath": (self.home / ".local/bin" / executable).as_posix(),
                       "commandArgs": ["acp"]},
        }

    def expected_codex(self, os_name=None):
        if os_name is None:
            os_name = self.chez("execute-template", "{{ .chezmoi.os }}").stdout
        executable = "codex.exe" if os_name == "windows" else "codex"
        return {
            "driver": "codex", "enabled": True,
            "config": {"enabled": True, "setupMode": "existing",
                       "binaryPath": (self.home / ".local/bin" / executable).as_posix()},
        }

    def render(self, body, os_name, arch, *, existing="", distro="ubuntu"):
        context = ('(dict "t3CodePreferences" (fromJson ' + json.dumps(json.dumps(self.preferences))
                   + ') "chezmoi" (dict "os" ' + json.dumps(os_name)
                   + ' "arch" ' + json.dumps(arch)
                   + ' "osRelease" (dict "id" ' + json.dumps(distro) + ')'
                   + ' "destDir" ' + json.dumps(self.home.as_posix())
                   + ' "stdin" ' + json.dumps(existing) + '))')
        wrapper = ('{{ template "fixture" ' + context + ' }}'
                   + '{{ define "fixture" }}' + body + '{{ end }}')
        return self.chez("execute-template", input=wrapper).stdout

    def test_missing_empty_and_missing_provider_objects_initialize_minimally(self):
        cases = (None, "", " \n\t", "{}", '{"preferences":{"theme":"dark"}}',
                 '{"providerInstances":{}}', '{"providerInstances":{"omp":{}}}',
                 '{"providerInstances":{"codex":{"config":{}}}}')
        for existing in cases:
            with self.subTest(existing=existing):
                self.settings.parent.mkdir(parents=True, exist_ok=True)
                self.settings.unlink(missing_ok=True)
                if existing is not None:
                    self.settings.write_text(existing, encoding="utf-8")
                self.apply()
                expected = dict(self.preferences["server"], providerInstances={
                    "omp": self.expected_provider(), "codex": self.expected_codex()})
                if existing and "preferences" in existing:
                    expected["preferences"] = {"theme": "dark"}
                self.assertEqual(self.read_settings(), expected)
                before = self.settings.read_bytes()
                self.apply()
                self.assertEqual(self.settings.read_bytes(), before)
                self.assertEqual(self.chez("diff", "--exclude=scripts").stdout, "")

    def test_owned_drift_converges_and_unowned_nested_values_survive(self):
        original = {
            "preferences": {"theme": "custom", "nested": [1, None, {"keep": True}]},
            "providerInstances": {
                "unrelated": {"driver": "codex", "enabled": False, "custom": {"keep": "雪"}},
                "codex": {
                    "driver": "stale", "enabled": False, "displayName": "My Codex",
                    "accentColor": None, "custom": [1, None],
                    "config": {"enabled": False, "setupMode": "managed", "binaryPath": "old",
                               "launchArgs": "--config model_reasoning_effort=low",
                               "custom": {"keep": "雪"}},
                },
                "omp": {
                    "driver": "stale", "enabled": True, "displayName": "My agent",
                    "accentColor": "#123456", "unowned": {"array": [False, {"keep": None}]},
                    "config": {"enabled": False, "source": "remote",
                               "commandPath": "old executable", "commandArgs": ["old"],
                               "env": {"TOKEN_NAME": "fixture-only"}, "custom": [None, 7]},
                },
            },
        }
        self.write_settings(original)
        self.apply()
        expected = dict(json.loads(json.dumps(original)), **self.preferences["server"])
        provider = expected["providerInstances"]["omp"]
        desired = self.expected_provider()
        provider.update(driver=desired["driver"], enabled=True)
        provider["config"].update(desired["config"])
        codex = expected["providerInstances"]["codex"]
        codex.update(driver="codex", enabled=True)
        codex["config"].update(self.expected_codex()["config"])
        self.assertEqual(self.read_settings(), expected)
        converged = self.settings.read_bytes()
        self.apply()
        self.assertEqual(self.settings.read_bytes(), converged)
        drifted = self.read_settings()
        drifted["providerInstances"]["omp"]["driver"] = "wrong"
        drifted["providerInstances"]["omp"]["enabled"] = False
        drifted["providerInstances"]["omp"]["config"].update(
            enabled=False, source="remote", commandPath="drift", commandArgs=[])
        drifted["providerInstances"]["codex"].update(driver="wrong", enabled=False)
        drifted["providerInstances"]["codex"]["config"].update(
            enabled=False, setupMode="managed", binaryPath="drift")
        self.write_settings(drifted)
        self.apply()
        self.assertEqual(self.read_settings(), expected)
        self.assertEqual(set(self.read_settings()["providerInstances"]), {"omp", "codex", "unrelated"})

    def test_existing_presentation_keys_are_not_owned_even_when_null(self):
        self.write_settings({"providerInstances": {"omp": {"displayName": None, "accentColor": ""}}})
        self.apply()
        expected = self.expected_provider()
        expected.update(displayName=None, accentColor="")
        self.assertEqual(self.read_settings(), dict(self.preferences["server"], providerInstances={
            "omp": expected, "codex": self.expected_codex()}))

    def test_existing_native_codex_options_and_presentation_survive_reapply(self):
        codex = self.expected_codex()
        codex.update(displayName="Local Codex", accentColor="#abcdef",
                     environment=[{"name": "EXAMPLE", "value": "fixture", "sensitive": False}])
        codex["config"].update(launchArgs="--config model_reasoning_effort=low",
                               homePath="/custom/codex/home", customModels=["custom-model"])
        self.write_settings({"providerInstances": {"codex": codex}})
        self.apply()
        expected = dict(self.preferences["server"], providerInstances={
            "codex": codex, "omp": self.expected_provider()})
        self.assertEqual(self.read_settings(), expected)
        before = self.settings.read_bytes()
        self.apply()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_invalid_json_and_incompatible_object_boundaries_preserve_bytes(self):
        originals = [b'{ "providerInstances": ', b"{bad json}", b"null", b"[]", b"false", b'"text"', b"42"]
        for invalid in (None, [], "text", 42, False):
            originals.extend(json.dumps(value).encode("utf-8") for value in (
                {"providerInstances": invalid},
                {"providerInstances": {"omp": invalid}},
                {"providerInstances": {"omp": {"config": invalid}}},
                {"providerInstances": {"codex": invalid}},
                {"providerInstances": {"codex": {"config": invalid}}},
            ))
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        for original in originals:
            with self.subTest(original=original):
                self.settings.write_bytes(original)
                result = self.apply(check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.settings.read_bytes(), original)

    def test_supported_platform_wrappers_render_absolute_canonical_paths(self):
        body = (self.repo / "home/private_dot_t3/private_userdata/modify_private_settings.json").read_text(encoding="utf-8")
        for os_name, arch in (("windows", "amd64"), ("windows", "arm64"),
                              ("linux", "amd64"), ("linux", "arm64"), ("darwin", "arm64")):
            with self.subTest(os=os_name, arch=arch):
                rendered = json.loads(self.render(body, os_name, arch))
                self.assertEqual(rendered, dict(self.preferences["server"], providerInstances={
                    "omp": self.expected_provider(os_name), "codex": self.expected_codex(os_name)}))
                self.assertTrue(Path(rendered["providerInstances"]["omp"]["config"]["commandPath"]).is_absolute())
                self.assertTrue(Path(rendered["providerInstances"]["codex"]["config"]["binaryPath"]).is_absolute())

    def test_configuration_and_parent_directories_are_private(self):
        for _ in range(2):
            self.apply()
            result = self.chez("dump", "--format=json", "--parent-dirs", str(self.settings))
            state = json.loads(result.stdout)
            for target, mode in ((".t3", 0o700), (".t3/userdata", 0o700), (".t3/userdata/settings.json", 0o600)):
                self.assertEqual(state[target]["perm"], mode)
                if os.name != "nt":
                    self.assertEqual((self.home / target).stat().st_mode & 0o777, mode)

    def write_preferences(self, server, client):
        data = self.source / ".chezmoidata/t3-code.json"
        data.parent.mkdir(exist_ok=True)
        data.write_text(json.dumps({"t3CodePreferences": {
            "server": server, "client": client}}), encoding="utf-8")

    def test_capture_keeps_current_models_and_fills_only_absent_defaults(self):
        desired = self.preferences["server"]
        self.assertEqual(desired["defaultModelSelection"], {
            "instanceId": "codex", "model": "gpt-6.1-sol",
            "options": [{"id": "reasoningEffort", "value": "high"},
                        {"id": "serviceTier", "value": "default"}],
        })
        self.assertEqual(desired["textGenerationModelSelection"],
                         {"instanceId": "codex", "model": "gpt-6-luna"})
        self.assertEqual(desired["defaultRuntimeMode"], "full-access")
        self.assertEqual(desired["sidebarAutoSettleAfterDays"], 3)
        self.assertIs(desired["sidebarAutoSettleOnMerge"], True)
        self.assertEqual(desired["storageCleanup"]["worktreeAfterDays"], 5)

    def test_declared_preferences_converge_without_losing_unowned_values(self):
        server = {
            "defaultAutoPull": False,
            "sidebarAutoSettleAfterDays": None,
            "addProjectBaseDirectory": "",
            "defaultModelSelection": {"instanceId": "codex", "model": "fixture-model"},
            "fallbackModelSelection": None,
            "textGenerationModelSelection": {"instanceId": "codex", "model": "fixture-text"},
            "storageCleanup": {"worktreeAfterDays": 0, "worktreeOnDelete": False},
            "sourceControlWritingStyle": {"mode": "custom", "customInstructions": ""},
        }
        client = {"notificationMode": "never", "inAppNotificationsEnabled": False,
                  "sidebarWorkingShelfEnabled": False, "snapShotEnabled": False}
        self.write_preferences(server, client)
        original = {
            "defaultAutoPull": True,
            "defaultModelSelection": {"instanceId": "codex", "model": "old",
                                      "options": [{"id": "reasoningEffort", "value": "old"}]},
            "textGenerationModelSelection": {"instanceId": "codex", "model": "old",
                                             "options": [{"id": "reasoningEffort", "value": "old"}]},
            "storageCleanup": {"worktreeAfterDays": 99, "unknown": "keep"},
            "sourceControlWritingStyle": {"mode": "old", "followChangeRequestTemplates": False},
            "projectSettingsOverrides": {"local-project": {"defaultAutoPull": True}},
            "idleCompaction": "onReturn",
        }
        self.write_settings(original)
        client_path = self.settings.with_name("client-settings.json")
        client_path.write_text(json.dumps({"snapShotEnabled": True, "fontSizeCode": 22,
                                           "snapShotSound": "keep"}), encoding="utf-8")
        self.apply()
        result = self.read_settings()
        for key, expected in server.items():
            if key == "storageCleanup":
                expected = dict(expected, unknown="keep")
            elif key == "sourceControlWritingStyle":
                expected = dict(expected, followChangeRequestTemplates=False)
            self.assertEqual(result[key], expected, key)
        self.assertEqual(result["projectSettingsOverrides"], original["projectSettingsOverrides"])
        self.assertEqual(result["idleCompaction"], "onReturn")
        self.assertEqual(json.loads(client_path.read_text()),
                         dict(client, fontSizeCode=22, snapShotSound="keep"))
        before = (self.settings.read_bytes(), client_path.read_bytes())
        self.apply()
        self.assertEqual((self.settings.read_bytes(), client_path.read_bytes()), before)
        self.assertEqual(self.chez("diff", "--exclude=scripts").stdout, "")

    def test_client_and_nested_preference_shape_errors_preserve_original_bytes(self):
        self.write_preferences({"storageCleanup": {"worktreeAfterDays": 5},
                                "sourceControlWritingStyle": {"mode": "custom"}},
                               {"snapShotEnabled": True})
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        client = self.settings.with_name("client-settings.json")
        for original in (b"{bad json}", b"null", b"[]", b"false", b"42", b'"text"'):
            with self.subTest(client=original):
                client.write_bytes(original)
                self.assertNotEqual(self.apply(check=False).returncode, 0)
                self.assertEqual(client.read_bytes(), original)
        client.unlink()
        for key in ("storageCleanup", "sourceControlWritingStyle"):
            for invalid in (None, [], "text", 42, False):
                with self.subTest(parent=key, value=invalid):
                    original = json.dumps({key: invalid}).encode()
                    self.settings.write_bytes(original)
                    self.assertNotEqual(self.apply(check=False).returncode, 0)
                    self.assertEqual(self.settings.read_bytes(), original)

    def install_selection_fixture(self):
        shutil.copytree(self.repo / "home/dot_config", self.source / "dot_config")
        (self.source / "dot_local/bin").mkdir(parents=True)
        # Materialization and selection are tested independently of native launch.
        for name in ("executable_t3.tmpl", "t3.cmd.tmpl"):
            shutil.copy2(self.repo / "home/dot_local/bin" / name, self.source / "dot_local/bin" / name)
        for path in (self.repo / "home/.chezmoitemplates").iterdir():
            if path.is_file() and path.name.startswith("t3-code-"):
                shutil.copy2(path, self.source / ".chezmoitemplates" / path.name)

    def test_actual_managed_targets_respect_platform_and_architecture(self):
        self.install_selection_fixture()
        ignore = (self.repo / "home/.chezmoiignore").read_text(encoding="utf-8")
        cases = (("windows", "amd64", "", True), ("windows", "arm64", "", True),
                 ("linux", "amd64", "ubuntu", True), ("linux", "arm64", "ubuntu", True),
                 ("darwin", "arm64", "", True), ("darwin", "amd64", "", False),
                 ("linux", "amd64", "debian", False), ("linux", "386", "ubuntu", False),
                 ("windows", "386", "", False), ("freebsd", "amd64", "", False))
        for os_name, arch, distro, supported in cases:
            with self.subTest(os=os_name, arch=arch, distro=distro):
                (self.source / ".chezmoiignore").write_text(
                    self.render(ignore, os_name, arch, distro=distro), encoding="utf-8")
                managed = set(self.chez("managed", "--path-style=relative", "--exclude=scripts").stdout.replace("\\", "/").splitlines())
                self.assertEqual(".t3/userdata/settings.json" in managed, supported)
                self.assertEqual(".local/bin/t3.cmd" in managed, supported and os_name == "windows")
                self.assertEqual(".local/bin/t3" in managed, supported and os_name != "windows")
                self.assertEqual(".config/dotfiles/path.sh" in managed,
                                 os_name == "linux" or (os_name == "darwin" and arch == "arm64"))
                self.assertEqual(".config/environment.d/60-native-system-ca.conf" in managed, os_name == "linux")

    def test_macos_selection_really_materializes_shared_path_fragment_only(self):
        shutil.copytree(self.repo / "home/dot_config", self.source / "dot_config")
        ignore = (self.repo / "home/.chezmoiignore").read_text(encoding="utf-8")
        (self.source / ".chezmoiignore").write_text(self.render(ignore, "darwin", "arm64"), encoding="utf-8")
        self.apply()
        fragment = self.home / ".config/dotfiles/path.sh"
        self.assertEqual(fragment.read_bytes(), (self.repo / "home/dot_config/dotfiles/path.sh").read_bytes())
        self.assertFalse((self.home / ".config/environment.d").exists())


if __name__ == "__main__":
    unittest.main()
