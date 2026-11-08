"""Verify pinned shared CE and skill assets in a disposable home.

Native harness discovery is covered by each harness's own smoke check.
No personal PATH, registry, account, or real home settings are changed.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import tomllib

from asset_fixtures import copy_asset_templates, harness_skill_names
from smoke_personal_apps import REPO, executable, run, temporary_destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    pins = json.loads((REPO / "home/.chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))
    name = "compound-engineering"
    pin = pins["harnessPluginLocks"][name]
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / part for part in ("home ' 한글", "source", "outside"))
        for directory in (home, source, outside):
            directory.mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        copy_asset_templates(source, ("harness-plugins", "harness-skills"))
        config = root / "chezmoi.toml"
        config.write_text("", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "HOME": str(home), "USERPROFILE": str(home),
            "APPDATA": str(root / "config"), "LOCALAPPDATA": str(root / "local"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
        })
        command = [chezmoi, "--config", str(config), "--source", str(source),
                   "--destination", str(home), "--cache", str(root / "chezmoi-cache"),
                   "--persistent-state", str(root / "chezmoi-state.boltdb"), "--no-tty"]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and args.expected_target != target:
            raise RuntimeError(f"Expected native {args.expected_target}, got {target}")
        manifest = tomllib.loads(chez("execute-template", '{{ includeTemplate "external-assets-manifest" . }}'))
        entry = manifest.get(".local/share/dotfiles/harness-plugins/" + name)
        if not entry or pin["commit"] not in entry["url"] or not entry["exact"]:
            raise RuntimeError(f"No exact committed CE payload for {target}")
        unrelated = home / ".local/share/dotfiles/harness-plugins/unrelated/state"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_bytes(b"unrelated plugin state\n")
        chez("apply", "--force")
        managed = home / ".local/share/dotfiles/harness-plugins" / name
        skill = managed / "skills/ce-pov/SKILL.md"
        original_skill = skill.read_bytes()
        if b"Form a Point of View" not in original_skill:
            raise RuntimeError("Pinned CE payload is missing the ce-pov skill")
        skill_roots = [path for path in manifest if "/skills/" in path]
        for skill_name in harness_skill_names():
            matches = [path for path in skill_roots if path.endswith("/" + skill_name)]
            if not matches:
                raise RuntimeError(f"No shared skill root for {skill_name}")
            for location in matches:
                if not (home / location / "SKILL.md").is_file():
                    raise RuntimeError(f"Shared skill was not materialized: {location}")
        snapshot = {path: (home / path / "SKILL.md").read_bytes() for path in skill_roots}
        before = skill.stat().st_mtime_ns
        chez("apply", "--force")
        if skill.stat().st_mtime_ns != before:
            raise RuntimeError("Unchanged apply rewrote the pinned CE payload")
        skill.write_bytes(b"local source drift\n")
        selected = next(iter(snapshot))
        (home / selected / "SKILL.md").write_bytes(b"local skill drift\n")
        chez("apply", "--force")
        if skill.read_bytes() != original_skill:
            raise RuntimeError("Apply did not repair the pinned CE payload")
        if any((home / path / "SKILL.md").read_bytes() != content for path, content in snapshot.items()):
            raise RuntimeError("Apply did not preserve and repair pinned shared skills")
        if unrelated.read_bytes() != b"unrelated plugin state\n":
            raise RuntimeError("Apply changed unrelated plugin state")
        binary_name = "omp.exe" if os.name == "nt" else "omp"
        if (home / ".omp").exists() or (home / ".local/bin" / binary_name).exists():
            raise RuntimeError("Fresh asset application acquired retired omp state")
        print(f"Native {target}: CE {pin['tag']} ({pin['commit']})")
        print("Verified: pinned shared payloads, skill roots, unchanged apply, drift repair, "
              "unrelated state preservation, and no fresh omp installation")


if __name__ == "__main__":
    main()
