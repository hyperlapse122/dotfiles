"""Prepare only fixture-selected assets without enabling personal apply scripts."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import time


REPO = Path(__file__).resolve().parents[1]
ASSET_DIRECTORY = ".chezmoitemplates/external-assets"


def preserve_mise_directories(env):
    """Keep installed tools reachable when a fixture relocates HOME and XDG."""
    if os.name == "nt":
        data = Path(env["LOCALAPPDATA"]) / "mise"
        cache = data / "cache"
    else:
        data = Path(env.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "mise"
        cache = Path(env.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "mise"
    env.setdefault("MISE_DATA_DIR", str(data))
    env.setdefault("MISE_CACHE_DIR", str(cache))


def harness_skill_names():
    """Every skill the harness-skills asset places in each shared skill root."""
    declared = json.loads((REPO / "home/.chezmoidata/harness-skills.json").read_text(encoding="utf-8"))
    return sorted(name for skill_set in declared["harnessSkills"].values() for name in skill_set["skills"])


def copy_asset_templates(source, names):
    source = Path(source)
    templates = source / ".chezmoitemplates"
    templates.mkdir(parents=True, exist_ok=True)
    for name in names:
        target = source / ASSET_DIRECTORY / (name + ".toml.tmpl")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / "home" / ASSET_DIRECTORY / target.name, target)
    shutil.copy2(REPO / "home/.chezmoitemplates/external-asset-roots", templates)
    (templates / "external-assets-manifest").write_text(
        "\n".join('{{ includeTemplate "external-assets/' + name + '.toml.tmpl" . }}'
                  for name in names) + "\n", encoding="utf-8")


def run_with_assets(arguments, *, env, phase_reporter=None, **kwargs):
    """Run fixture chezmoi, preparing assets before apply with its exact context."""
    def run_phase(label, command, **options):
        started = time.monotonic()
        if phase_reporter:
            phase_reporter(label, None)
        try:
            return subprocess.run(command, **options)
        finally:
            if phase_reporter:
                phase_reporter(label, time.monotonic() - started)

    command = list(map(str, arguments))
    if "apply" not in command or "--source" not in command or "--destination" not in command:
        return run_phase("native command", command, env=env, **kwargs)
    apply_index = command.index("apply")
    base = command[:apply_index]
    source = Path(base[base.index("--source") + 1])
    if (source / ".chezmoiroot").is_file():
        source = source / (source / ".chezmoiroot").read_text().strip()
    if not (source / ".chezmoitemplates/external-assets-manifest").is_file():
        return run_phase("chezmoi apply", command, env=env, **kwargs)
    destination = Path(base[base.index("--destination") + 1])
    cache = Path(base[base.index("--cache") + 1]) / "fixture-assets"
    inputs = cache / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    render_options = dict(env=env, capture_output=True, text=True, encoding="utf-8",
                          errors="backslashreplace", timeout=120)
    for template, filename in (("external-assets-manifest", "manifest.toml"),
                               ("external-asset-roots", "roots.tsv")):
        result = run_phase("render " + template,
                           base + ["execute-template", '{{ includeTemplate "' + template + '" . }}'],
                           **render_options)
        if result.returncode:
            return result
        (inputs / filename).write_text(result.stdout, encoding="utf-8", newline="\n")
    params = [str(inputs / "manifest.toml"), str(inputs / "roots.tsv"), str(destination),
              str(cache), command[0], env.get("DOTFILES_ASSET_MODE", "normal")]
    if os.name == "nt":
        prepare = [shutil.which("powershell.exe"), "-NoProfile", "-NonInteractive",
                   "-ExecutionPolicy", "Bypass", "-File", str(REPO / "scripts/prepare-external-assets.ps1")]
    else:
        prepare = ["/bin/sh", str(REPO / "scripts/prepare-external-assets.sh")]
    prepare_options = dict(render_options, timeout=kwargs.get("timeout", 120))
    result = run_phase("prepare external assets", prepare + params, **prepare_options)
    if result.returncode:
        return result
    return run_phase("chezmoi apply", command, env=env, **kwargs)
