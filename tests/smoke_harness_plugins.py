"""Apply real omp/CE pins and exercise native discovery in a disposable home.

No personal PATH, registry, account, or real home settings are changed.
"""

import argparse
import json
import os
from pathlib import Path
import shutil

from asset_fixtures import copy_asset_templates
from smoke_personal_apps import REPO, check_version, executable, run, temporary_destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    declarations = json.loads((REPO / "home/.chezmoidata/harness-plugins.json").read_text(encoding="utf-8"))
    pins = json.loads((REPO / "home/.chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))
    app_pins = json.loads((REPO / "home/.chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))
    name = "compound-engineering"
    plugin = declarations["harnessPlugins"][name]
    pin = pins["harnessPluginLocks"][name]
    plugin_id = plugin["omp"]["plugin"] + "@" + plugin["omp"]["marketplace"]

    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / part for part in ("home ' 한글", "source", "outside"))
        for directory in (home, source, outside):
            directory.mkdir()
        # Stop native nearest-project discovery before it reaches an ancestor's
        # real .omp directory when the OS temp directory is below the real home.
        (outside / ".omp").mkdir()
        for relative in (
            ".chezmoidata/personal-apps.json",
            ".chezmoidata/personal-app-lock.json",
            ".chezmoidata/harness-plugins.json",
            ".chezmoidata/harness-plugin-lock.json",
            ".chezmoidata/harness-skills.json",
            ".chezmoitemplates",
            "private_dot_omp",
            ".chezmoiscripts/run_onchange_after_20-harness-plugins.ps1.tmpl",
            ".chezmoiscripts/run_onchange_after_20-harness-plugins.sh.tmpl",
        ):
            origin, destination = REPO / "home" / relative, source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if origin.is_dir():
                shutil.copytree(origin, destination)
            else:
                shutil.copy2(origin, destination)
        # Keep only this feature's conditional ignores, rather than enabling
        # unrelated personal app/PATH/GPG scripts in the smoke source.
        shutil.copy2(REPO / "home/.chezmoiignore", source / ".chezmoiignore")
        copy_asset_templates(source, ('personal-apps', 'harness-plugins', 'harness-skills'))
        config = root / "chezmoi.toml"
        config_text = ""
        if os.name == "nt":
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config_text = ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
                           '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config.write_text(config_text, encoding="utf-8")
        env = os.environ.copy()
        for key in (
            "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "PI_CONFIG_FILES", "PI_PACKAGE_DIR",
            "OMP_PROFILE", "PI_PROFILE", "ZDOTDIR",
        ):
            env.pop(key, None)
        env.update({
            "HOME": str(home), "USERPROFILE": str(home),
            "APPDATA": str(root / "config"), "LOCALAPPDATA": str(root / "local"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"),
            "CODEX_HOME": str(home / ".codex"), "NO_COLOR": "1",
        })
        command = [
            chezmoi, "--config", str(config), "--source", str(source),
            "--destination", str(home), "--cache", str(root / "chezmoi-cache"),
            "--persistent-state", str(root / "chezmoi-state.boltdb"), "--no-tty",
        ]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and args.expected_target != target:
            raise RuntimeError(f"Expected native {args.expected_target}, got {target}")
        if target not in app_pins["personalAppLocks"]["omp"]["targets"]:
            raise RuntimeError(f"No committed omp binary for {target}")
        # Download and materialize only managed files first. Subsequent calls
        # below exercise the real after-script, not an imitation of its commands.
        chez("apply", "--force", "--exclude=scripts")
        binary = home / ".local/bin" / ("omp.exe" if os.name == "nt" else "omp")
        managed = home / ".local/share/dotfiles/harness-plugins" / name

        def omp(*arguments):
            return run([str(binary), *arguments], env=env, cwd=outside)

        version = omp("--version")
        check_version(version, app_pins["personalAppLocks"]["omp"]["tag"])
        original_skill = (managed / "skills/ce-pov/SKILL.md").read_bytes()
        # Seed native state, then simulate a preexisting moving remote CE source
        # without cloning that remote or resolving anything beyond committed pins.
        omp("plugin", "marketplace", "add", str(managed))
        registry_path = home / ".omp/marketplaces.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        for entry in registry["marketplaces"]:
            if entry["name"] == plugin["omp"]["marketplace"]:
                entry["sourceUri"] = "https://github.com/" + plugin["repository"]
        registry_path.write_text(json.dumps(registry), encoding="utf-8")

        unrelated = root / "unrelated-plugin"
        (unrelated / ".omp-plugin").mkdir(parents=True)
        (unrelated / "package.json").write_text(json.dumps({
            "name": "smoke-unrelated", "version": "1.0.0",
        }), encoding="utf-8")
        (unrelated / ".omp-plugin/marketplace.json").write_text(json.dumps({
            "name": "smoke-unrelated", "owner": {"name": "isolated smoke"},
            "plugins": [{"name": "smoke-unrelated", "source": "./", "version": "1.0.0"}],
        }), encoding="utf-8")
        omp("plugin", "marketplace", "add", str(unrelated))
        omp("plugin", "install", "smoke-unrelated@smoke-unrelated", "--scope", "user")
        installed_path = home / ".omp/plugins/installed_plugins.json"
        unrelated_before = json.loads(installed_path.read_text(encoding="utf-8"))["plugins"]["smoke-unrelated@smoke-unrelated"]
        runtime_path = home / ".omp/plugins/omp-plugins.lock.json"
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
        runtime["plugins"]["smoke-unrelated"]["settings"] = {"fixtureValue": "retain-me"}
        runtime_path.write_text(json.dumps(runtime), encoding="utf-8")

        chez("apply", "--force")
        installed = json.loads(installed_path.read_text(encoding="utf-8"))["plugins"]
        entries = installed[plugin_id]
        entry = next(item for item in entries if item["scope"] == "user")
        cache = Path(entry["installPath"])
        if (cache / "skills/ce-pov/SKILL.md").read_bytes() != original_skill:
            raise RuntimeError("Native installed CE skill differs from the committed source")
        if omp("config", "get", "marketplace.autoUpdate").strip() != "off":
            raise RuntimeError("Native omp did not read the managed automatic-update setting")
        discovery = omp("read", "skill://ce-pov:1-20")
        if "Form a Point of View" not in discovery:
            raise RuntimeError("Fresh native skill discovery did not find CE ce-pov: " + discovery)
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        ce_registry = next(item for item in registry["marketplaces"] if item["name"] == plugin["omp"]["marketplace"])
        if Path(ce_registry["sourceUri"]).resolve() != managed.resolve():
            raise RuntimeError("CE marketplace still follows a moving remote source")
        source_pins = json.loads((source / ".chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))
        source_pins["harnessPluginLocks"]["unconfigured"] = {"commit": "0" * 40}
        (source / ".chezmoidata/harness-plugin-lock.json").write_text(json.dumps(source_pins, indent=4), encoding="utf-8")
        source_apps = json.loads((source / ".chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))
        other_target = next(key for key in source_apps["personalAppLocks"]["omp"]["targets"] if key != target)
        source_apps["personalAppLocks"]["omp"]["targets"][other_target]["sha256"] = "0" * 64
        (source / ".chezmoidata/personal-app-lock.json").write_text(json.dumps(source_apps, indent=4), encoding="utf-8")
        (source / ".chezmoidata/unrelated.yaml").write_text("unrelated: changed\n", encoding="utf-8")
        if chez("status", "--include=scripts"):
            raise RuntimeError("Successful onchange reconciliation is still pending")

        omp("plugin", "disable", plugin_id, "--scope", "user")
        (cache / "skills/ce-pov/SKILL.md").write_text("local cache drift", encoding="utf-8")
        (managed / "skills/ce-pov/SKILL.md").write_text("local source drift", encoding="utf-8")
        chez("apply", "--force")
        if (managed / "skills/ce-pov/SKILL.md").read_bytes() != original_skill:
            raise RuntimeError("Unchanged apply did not repair the managed source")
        if (cache / "skills/ce-pov/SKILL.md").read_text(encoding="utf-8") != "local cache drift":
            raise RuntimeError("Unchanged apply unexpectedly reran native installation")
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
        if runtime["plugins"]["compound-engineering"]["enabled"] is not False:
            raise RuntimeError("Unchanged apply unexpectedly reset native enabled state")
        helper = source / ".chezmoitemplates/harness-plugin-marketplaces"
        with helper.open("a", encoding="utf-8") as stream:
            stream.write("{{/* smoke: consumed template change */}}\n")
        chez("apply", "--force")
        if (cache / "skills/ce-pov/SKILL.md").read_bytes() != original_skill:
            raise RuntimeError("Consumed-template change did not repair native same-version cache drift")
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
        if runtime["plugins"]["compound-engineering"]["enabled"] is not True:
            raise RuntimeError("Consumed-template change did not enable the managed CE plugin")
        if runtime["plugins"]["smoke-unrelated"]["settings"] != {"fixtureValue": "retain-me"}:
            raise RuntimeError("Apply discarded unrelated plugin settings")
        installed = json.loads(installed_path.read_text(encoding="utf-8"))["plugins"]
        if installed["smoke-unrelated@smoke-unrelated"] != unrelated_before:
            raise RuntimeError("Apply changed an unrelated plugin installation")
        if chez("status", "--include=scripts"):
            raise RuntimeError("Reconciled onchange action remains pending")
        # Managed source/config and the successful action should now be stable.
        if chez("diff", "--exclude=scripts"):
            raise RuntimeError("Managed source/config still differs after reconciliation")
        print(f"Native {target}: {version}; CE {pin['tag']} ({pin['commit']})")
        print("Verified: local-source cutover, native skill URI discovery, autoUpdate=off, "
              "unchanged-action skipping, template-triggered cache repair, enabled state, "
              "unrelated plugin preservation, and clean file diff")


if __name__ == "__main__":
    main()
