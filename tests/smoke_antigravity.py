"""Apply locked Antigravity CLI/CE without claiming T3’s native provider ID.

The default run uses no external model request, personal OAuth, real keyring operation, or personal apply.
Native instruction discovery uses a localhost capture-only endpoint that rejects requests.
An explicit --authenticated run uses GEMINI_API_KEY for a real native CE invocation.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from asset_fixtures import copy_asset_templates
from smoke_personal_apps import REPO, check_version, executable, run, temporary_destination
from smoke_codex import capture_requests, strings

CE_PROMPT = ("/ce-noslop mode:edit Before rewriting, use read_file to load the discovered ce-noslop SKILL.md. "
             "Read no other files and use no other tools. Rewrite only this sentence and return only it: "
             "The dotfiles verification returned AGY_CE_NATIVE_OK.")


def verify_authenticated_invocation(transcript, selected_skill):
    try:
        events = [json.loads(line) for line in transcript.splitlines() if line.strip()]
    except ValueError:
        raise RuntimeError("Authenticated native CE events could not be parsed") from None
    skill_bytes = selected_skill.read_bytes()
    expected_read = f"{len(skill_bytes.splitlines())} lines, {len(skill_bytes)} bytes"
    read_complete = False
    for event in events[:-1]:
        step = event.get("step_update", {})
        info = step.get("tool_info", {})
        path = info.get("parameters", {}).get("Path")
        if (step.get("state") == "DONE" and step.get("step_type") == "tool"
                and step.get("tool_name") == "read_file" and isinstance(path, str)
                and Path(path).resolve() == selected_skill.resolve()
                and info.get("output") == expected_read):
            read_complete = True
    result = events[-1].get("result", {}) if events and events[-1].get("event") == "result" else {}
    if (not read_complete or result.get("status") != "SUCCESS"
            or result.get("response", "").strip() != "The dotfiles verification returned AGY_CE_NATIVE_OK."):
        raise RuntimeError("Authenticated native CE completion or full pinned skill read was not proven")


def authenticated_environment(original, isolated):
    key = original.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("--authenticated requires an explicitly provisioned GEMINI_API_KEY")
    result = isolated.copy()
    result["GEMINI_API_KEY"] = key
    result.pop("GOOGLE_GEMINI_BASE_URL", None)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    parser.add_argument("--authenticated", action="store_true",
                        help="Use GEMINI_API_KEY for a real CE invocation in the disposable home")
    args = parser.parse_args()
    if args.authenticated:
        authenticated_environment(os.environ, {})
    chezmoi = executable("chezmoi")
    real_environment = os.environ.copy()
    app_locks = json.loads((REPO / "home/.chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))["personalAppLocks"]
    ce_pin = json.loads((REPO / "home/.chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))["harnessPluginLocks"]["compound-engineering"]
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / name for name in ("user home", "source", "outside"))
        for directory in (home, source, outside):
            directory.mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates", "dot_local", "private_dot_gemini", "private_dot_t3"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        for relative in (".chezmoiignore", ".chezmoiremove", ".chezmoiscripts/run_after_20-antigravity-plugins.sh.tmpl",
                         ".chezmoiscripts/run_after_20-antigravity-plugins.ps1.tmpl"):
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / relative, destination)
        declaration = source / ".chezmoidata/personal-apps.json"
        apps = json.loads(declaration.read_text(encoding="utf-8"))
        apps["personalApps"] = {name: apps["personalApps"][name] for name in ("antigravity",)}
        declaration.write_text(json.dumps(apps), encoding="utf-8")
        markers = {"common": "DOTFILES_COMMON_NATIVE_RULE_71AE",
                   "antigravity": "DOTFILES_ANTIGRAVITY_NATIVE_RULE_9F26",
                   "foreign": "DOTFILES_FOREIGN_NATIVE_RULE_B8C1"}
        (source / ".chezmoitemplates/agent-instructions").write_text(
            markers["common"] + "\n"
            + '{{ if eq .harness "antigravity" }}' + markers["antigravity"] + "{{ end }}\n"
            + '{{ if ne .harness "antigravity" }}' + markers["foreign"] + "{{ end }}\n",
            encoding="utf-8")
        copy_asset_templates(source, ('personal-apps', 'harness-plugins', 'harness-skills'))
        config = root / "chezmoi.toml"
        config_text = ""
        if os.name == "nt":
            shell = Path(real_environment["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config_text = ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell))
                           + '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config.write_text(config_text, encoding="utf-8")
        env = real_environment.copy()
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "APPDATA": str(root / "appdata"),
            "LOCALAPPDATA": str(root / "local"), "ZDOTDIR": str(home),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "T3CODE_HOME": str(home / ".t3"),
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true", "NO_COLOR": "1",
        })
        for key in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "AGY_ADC_AUTH"):
            env.pop(key, None)
        # Missing API-key configuration fails before native account/keyring sign-in.
        cli_settings = home / ".gemini/antigravity-cli/settings.json"
        cli_settings.parent.mkdir(parents=True)
        cli_settings.write_text(json.dumps({"modelProvider": "gemini", "unrelatedSmokeSetting": "retain"}), encoding="utf-8")
        t3_settings = home / ".t3/userdata/settings.json"
        t3_settings.parent.mkdir(parents=True)
        disabled = {name: {"driver": name, "enabled": False, "config": {}}
                    for name in ("codex", "claudeAgent", "cursor", "grok", "opencode", "pi")}
        disabled["smoke-unrelated"] = {"driver": "codex", "enabled": False, "config": {"keep": "value"}}
        t3_settings.write_text(json.dumps({"idleCompaction": "onReturn", "providerInstances": disabled}), encoding="utf-8")
        command = [chezmoi, "--config", str(config), "--source", str(source), "--destination", str(home),
                   "--cache", str(root / "cache"), "--persistent-state", str(root / "state.boltdb"), "--no-tty"]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in app_locks["antigravity"]["targets"]:
            raise RuntimeError(f"No locked Antigravity target: {target}")
        chez("apply", "--force", "--exclude=scripts")
        binary_suffix = ".exe" if os.name == "nt" else ""
        cli = home / ".local/share/dotfiles/antigravity/bin" / ("agy" + binary_suffix)
        launcher_suffix = ".ps1" if os.name == "nt" else ""
        agy_launcher = home / ".local/bin" / ("agy" + launcher_suffix)

        def launch(path, *arguments):
            invocation = [str(path), *arguments]
            if os.name == "nt":
                shell = str(Path(real_environment["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
                invocation = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", *invocation]
            return run(invocation, env=env, cwd=outside)

        for name, path in (("antigravity", agy_launcher),):
            version = launch(path, "--version")
            check_version(version, app_locks[name]["tag"])
            print(f"Native {target}: {name} {version}")
        safe_capture_keys = {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP",
                             "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432", "HOME",
                             "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME",
                             "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"}
        capture_env = {key: value for key, value in env.items() if key.upper() in safe_capture_keys}
        with capture_requests() as (endpoint, requests):
            capture_env.update({"GEMINI_API_KEY": "local-capture-not-a-real-key",
                                "GOOGLE_GEMINI_BASE_URL": endpoint.removesuffix("/v1"),
                                "AGY_CLI_DISABLE_AUTO_UPDATE": "true", "NO_PROXY": "127.0.0.1,localhost"})
            captured = subprocess.run(
                [str(cli), "--print", "Inspect current workspace context without using tools.",
                 "--print-timeout", "15s", "--output-format", "json"],
                env=capture_env, cwd=outside, capture_output=True, text=True,
                encoding="utf-8", errors="replace", timeout=45)
        contexts = ["\n".join(strings(request)) for request in requests]
        if (captured.returncode == 0
                or not any(markers["common"] in text and markers["antigravity"] in text for text in contexts)
                or any(markers["foreign"] in text for text in contexts)):
            raise RuntimeError("Native instruction discovery was not proven: " + captured.stdout + captured.stderr)
        print("Native instruction discovery: common and Antigravity rules included, foreign rules excluded; localhost capture rejected model execution")
        chez("apply", "--force")
        plugins = json.loads(run([str(cli), "plugin", "list", "--json"], env=env, cwd=outside))
        managed = [plugin for plugin in plugins if plugin["name"] == "compound-engineering"]
        if len(managed) != 1 or not managed[0]["enabled"] or "ce-pov" not in managed[0]["skills"]:
            raise RuntimeError("Pinned CE is not enabled and natively discoverable")
        check_version(managed[0]["version"], ce_pin["tag"].removeprefix("compound-engineering-"))
        run([str(cli), "plugin", "validate", managed[0]["path"]], env=env, cwd=outside)
        native_checks_env = {**env, "ANTIGRAVITY_TEST_BINARY": str(cli), "PYTHONPATH": str(REPO / "tests")}
        run([sys.executable, "-m", "unittest", "test_harness_plugins.NativeAntigravityPluginsTest"],
            env=native_checks_env, cwd=outside)
        print("Native plugin preservation, enablement repair, and malformed-state checks passed")
        first = json.loads(t3_settings.read_text(encoding="utf-8"))
        if "antigravity" in first["providerInstances"]:
            raise RuntimeError("Apply claimed T3's native Antigravity provider ID")
        run([str(cli), "plugin", "disable", "compound-engineering"], env=env, cwd=outside)
        for _ in range(2):
            chez("apply", "--force")
        if json.loads(t3_settings.read_text(encoding="utf-8")) != first:
            raise RuntimeError("Repeated provider reconciliation did not converge")
        plugins = json.loads(run([str(cli), "plugin", "list", "--json"], env=env, cwd=outside))
        if not next(plugin for plugin in plugins if plugin["name"] == "compound-engineering")["enabled"]:
            raise RuntimeError("Reapply did not restore native CE enablement")
        print("Verified: pinned CLI, native instructions/CE discovery, plugin repair, and native T3 provider ID left untouched")
        if args.authenticated:
            auth_env = authenticated_environment(real_environment, env)
            completed = subprocess.run(
                [str(cli), "--print", CE_PROMPT, "--mode", "plan", "--print-timeout", "60s",
                 "--output-format", "stream-json"], env=auth_env, cwd=outside,
                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90)
            if completed.returncode:
                raise RuntimeError("Authenticated native CE invocation did not complete")
            selected_skill = Path(managed[0]["path"]) / "skills/ce-noslop/SKILL.md"
            verify_authenticated_invocation(completed.stdout, selected_skill)
            print(f"Authenticated {target}: native /ce-noslop completed with pinned CE {managed[0]['version']}; "
                  "common/Antigravity instruction inclusion and foreign exclusion verified by the independent capture above")
        else:
            print("Authenticated CE invocation not attempted; use --authenticated with an authorized GEMINI_API_KEY")
        print("T3's official ACP runtime remains separate from this CLI verification")


if __name__ == "__main__":
    main()
