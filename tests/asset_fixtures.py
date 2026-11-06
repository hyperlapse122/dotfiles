"""Prepare only fixture-selected assets without enabling personal apply scripts."""

import os
from pathlib import Path
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[1]
ASSET_DIRECTORY = ".chezmoitemplates/external-assets"


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


def run_with_assets(arguments, *, env, **kwargs):
    """Run fixture chezmoi, preparing assets before apply with its exact context."""
    command = list(map(str, arguments))
    if "apply" not in command or "--source" not in command or "--destination" not in command:
        return subprocess.run(command, env=env, **kwargs)
    apply_index = command.index("apply")
    base = command[:apply_index]
    source = Path(base[base.index("--source") + 1])
    if (source / ".chezmoiroot").is_file():
        source = source / (source / ".chezmoiroot").read_text().strip()
    if not (source / ".chezmoitemplates/external-assets-manifest").is_file():
        return subprocess.run(command, env=env, **kwargs)
    destination = Path(base[base.index("--destination") + 1])
    cache = Path(base[base.index("--cache") + 1]) / "fixture-assets"
    inputs = cache / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    render_options = dict(env=env, capture_output=True, text=True, encoding="utf-8",
                          errors="backslashreplace", timeout=120)
    for template, filename in (("external-assets-manifest", "manifest.toml"),
                               ("external-asset-roots", "roots.tsv")):
        result = subprocess.run(base + ["execute-template", '{{ includeTemplate "' + template + '" . }}'],
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
    result = subprocess.run(prepare + params, **prepare_options)
    if result.returncode:
        return result
    return subprocess.run(command, env=env, **kwargs)
