"""Prove the pinned Prezto environment in a disposable native zsh home."""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile

from asset_fixtures import copy_asset_templates, run_with_assets


REPO = Path(__file__).resolve().parents[1]


def run(arguments, *, env=None, cwd=REPO, startup=False):
    result = run_with_assets(arguments, env=env, cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="backslashreplace", timeout=300)
    startup_error = startup and any(message in result.stdout + result.stderr for message in (
        "Couldn't read file", "function definition file not found", "Module not loaded:",
    ))
    if result.returncode or startup_error:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments!r}\n{result.stdout}{result.stderr}")
    return (result.stdout + (result.stderr if startup else "")).strip()


def executable(name):
    found = shutil.which(name)
    if found is None:
        raise RuntimeError(f"Required native executable is unavailable: {name}")
    return str(Path(found).resolve())


def check_shell(zsh, env, outside, root, providers, *, interactive, login=False, missing=()):
    script = '''
[[ $ZDOTDIR == "$EXPECTED_ZSH_ROOT" && $NODE_USE_SYSTEM_CA == 1 ]] || exit 11
[[ -x "$HOME/.local/share/dotfiles/zsh/bin/usage" && -n $(command -v usage) ]] || exit 12
if [[ -o interactive ]]; then
  (( ${+_DOTFILES_ZSH_INITIALIZED} && ${+functions[mise]} )) || exit 13
  zstyle -a ':prezto:load' pmodule selected_modules
  for selected_module in $selected_modules; do
    zstyle -t ":prezto:module:$selected_module" loaded || { print -u2 "Module not loaded: $selected_module"; exit 14; }
  done
  for required_module in environment terminal editor history directory spectrum utility completion history-substring-search syntax-highlighting autosuggestions prompt; do
    zstyle -t ":prezto:module:$required_module" loaded || { print -u2 "Module not loaded: $required_module"; exit 14; }
  done
  if (( $+commands[git] )); then zstyle -t ':prezto:module:git' loaded || exit 14; fi
  if [[ $OSTYPE == darwin* ]] && (( $+commands[brew] )); then zstyle -t ':prezto:module:homebrew' loaded || exit 14; fi
  zstyle -s ':prezto:module:prompt' theme selected_theme
  [[ $selected_theme == sorin ]] || exit 18
  for selected_command in ${(s: :)EXPECTED_COMPLETIONS}; do
    [[ ${_comps[$selected_command]} == _$selected_command ]] || { print -u2 "Completion not registered: $selected_command (${_comps[$selected_command]})"; exit 15; }
  done
  for missing_command in ${(s: :)EXPECTED_MISSING_COMPLETIONS}; do
    [[ -z ${_comps[$missing_command]-} ]] || { print -u2 "Stale-cache fixture already registers $missing_command"; exit 19; }
  done
  _mise_hook_precmd
  cd .
  usage --version || exit 17
  candidate_output=$(command mise __complete_word__ --shell zsh --line 'mise inst') || exit 20
  [[ $candidate_output == install$'\t'* ]] || exit 20
  candidate_output=$(command usage __complete_word__ --shell zsh --line 'usage gen') || exit 21
  [[ $candidate_output == generate$'\t'* ]] || exit 21
else
  (( ! ${+_DOTFILES_ZSH_INITIALIZED} && ! ${+functions[pmodload]} && ! ${+functions[mise]} )) || exit 16
fi
print -r -- "zsh-ready:$ZDOTDIR"
'''
    flags = ["-d"] + (["-l"] if login else []) + (["-i"] if interactive else [])
    output = run([zsh, *flags, "-c", script], env=env | {
        "EXPECTED_ZSH_ROOT": str(root), "EXPECTED_COMPLETIONS": " ".join(providers),
        "EXPECTED_MISSING_COMPLETIONS": " ".join(missing),
    }, cwd=outside, startup=True)
    if f"zsh-ready:{root}" not in output:
        raise RuntimeError(f"Missing successful native startup signal: {output}")


def deny_startup_installation(home, real_mise, real_usage):
    stage = home / ".local/share/dotfiles/zsh"
    real_tools = {name: home / ".local/bin" / name
                  for name in ("codex", "omp", "gh", "glab", "ghq")}
    real_tools.update(mise=Path(real_mise), usage=Path(real_usage))
    for name, binary in real_tools.items():
        destination = stage / "bin" / name
        destination.unlink(missing_ok=True)
        destination.write_text(
            "#!/bin/sh\ncase \"$1\" in completion|completions|--completions|install|update)\n"
            "  printf '%s\\n' \"$0 $*\" >> \"$STARTUP_FORBIDDEN_CALLS\"; exit 90;;\nesac\n"
            + f"exec {shlex.quote(str(binary))} \"$@\"\n", encoding="utf-8")
        destination.chmod(0o755)
    for name in ("curl", "wget"):
        destination = stage / "bin" / name
        destination.write_text("#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \"$STARTUP_FORBIDDEN_CALLS\"\nexit 90\n", encoding="utf-8")
        destination.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target", required=True)
    args = parser.parse_args()
    architecture = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())
    operating_system = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    target = f"{operating_system}-{architecture}"
    manifest = json.loads((REPO / "home/.chezmoidata/zsh.json").read_text())["zsh"]
    if target != args.expected_target or target not in manifest["targets"]:
        raise RuntimeError(f"Expected eligible target {args.expected_target}, got {target}")
    zsh, chezmoi, mise, usage = (executable(name) for name in ("zsh", "chezmoi", "mise", "usage"))
    usage_root = Path(run([mise, "--cd", str(REPO), "where", "usage"]))
    mise_data = os.environ.get("MISE_DATA_DIR", str(usage_root.parents[2]))
    apps = json.loads((REPO / "home/.chezmoidata/personal-apps.json").read_text())["personalApps"]
    supported_apps = {name: app for name, app in apps.items()
                      if name in manifest["completions"] and target in app["targets"]}
    providers = [*supported_apps, "mise", "usage"]
    with tempfile.TemporaryDirectory(prefix="zsh native ' ") as temporary:
        root = Path(temporary)
        home, source, outside = (root / name for name in ("home", "source", "outside"))
        for directory in (home, source, outside):
            directory.mkdir()
        effective = home / ".config/zsh"
        effective.mkdir(parents=True)
        (effective / ".zshrc").write_text('source "$ZDOTDIR/.zprezto/init.zsh"\n')
        for relative in (".chezmoitemplates", "dot_local/share/dotfiles/zsh"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        for relative in (
            ".chezmoidata/zsh.json", ".chezmoidata/zsh-lock.json", ".chezmoidata/personal-app-lock.json",
            "modify_dot_zshenv",
            ".chezmoiscripts/run_onchange_after_10-personal-app-path.sh.tmpl",
            ".chezmoiscripts/run_after_40-zsh.sh.tmpl", "dot_config/dotfiles/path.sh",
        ):
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / relative, destination)
        copy_asset_templates(source, ("personal-apps", "codex-package", "zsh"))
        (source / ".chezmoidata/personal-apps.json").write_text(json.dumps({"personalApps": supported_apps}))
        config = root / "chezmoi.toml"
        config.write_text(f"workingTree = {json.dumps(str(REPO))}\n", encoding="utf-8")
        env = os.environ.copy()
        for name in ("ZDOTDIR", "XDG_CONFIG_HOME", "BASH_ENV", "ENV", "NODE_USE_SYSTEM_CA", "MISE_ENV", "MISE_CONFIG_FILE"):
            env.pop(name, None)
        env.update(HOME=str(home), USERPROFILE=str(home), TERM="xterm-256color",
                   XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
                   XDG_STATE_HOME=str(root / "state"), XDG_CONFIG_DIRS=str(root / "system-config"),
                   MISE_DATA_DIR=mise_data, MISE_CACHE_DIR=str(root / "mise-cache"),
                   MISE_TRUSTED_CONFIG_PATHS=str(REPO),
                   MISE_AUTO_INSTALL="false", GIT_CONFIG_GLOBAL=str(home / ".gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                   GNUPGHOME=str(home / ".gnupg"), SSH_AUTH_SOCK=str(root / "existing-agent"))
        # Preserve the caller's agent lifecycle instead of starting a disposable GPG daemon.
        (home / ".gnupg").mkdir()
        (home / ".gnupg/gpg-agent.conf").write_text("enable-ssh-support\n")
        command = [chezmoi, "--source", str(source), "--destination", str(home), "--config", str(config),
                   "--cache", str(root / "chezmoi-cache"), "--persistent-state", str(root / "chezmoi-state"),
                   "--no-tty", "apply", "--force"]
        run(command, env=env)
        stage = home / ".local/share/dotfiles/zsh"
        for provider in providers:
            run([zsh, "-n", str(stage / "completions" / ("_" + provider))], env=env)
        effective = home / ".config/zsh"
        for flags in ({"interactive": True}, {"interactive": True, "login": True}, {"interactive": False}):
            check_shell(zsh, env, outside, effective, providers, **flags)
        usage_completion = stage / "completions/_usage"
        hidden_completion = root / "saved-usage-completion"
        usage_completion.rename(hidden_completion)
        dump = root / "cache/prezto/zcompdump"
        dump.unlink(missing_ok=True)
        Path(str(dump) + ".zwc").unlink(missing_ok=True)
        check_shell(zsh, env, outside, effective, [name for name in providers if name != "usage"],
                    interactive=True, missing=("usage",))
        hidden_completion.rename(usage_completion)
        run(command, env=env)
        check_shell(zsh, env, outside, effective, providers, interactive=True)
        env["XDG_CONFIG_HOME"] = str(root / "outside config ' directory")
        legacy = root / "legacy zsh ' directory"
        legacy.mkdir()
        (legacy / ".zshenv").write_text("export LEGACY_ZSH_SETTING=preserved\n")
        env["ZDOTDIR"] = str(legacy)
        effective = Path(env["XDG_CONFIG_HOME"]) / "zsh"
        run(command, env=env)
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in [*effective.glob(".z*"), *stage.joinpath("completions").glob("_*")]
                  if path.is_file()}
        run(command, env=env)
        after = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in before}
        if before != after:
            raise RuntimeError("Unchanged apply rewrote startup or completion content")
        deny_startup_installation(home, mise, usage)
        forbidden = root / "forbidden-startup-calls"
        env.update(STARTUP_FORBIDDEN_CALLS=str(forbidden), HTTP_PROXY="http://127.0.0.1:9",
                   HTTPS_PROXY="http://127.0.0.1:9", ALL_PROXY="http://127.0.0.1:9")
        for flags in ({"interactive": True}, {"interactive": True, "login": True}, {"interactive": False}):
            check_shell(zsh, env, outside, effective, providers, **flags)
        check_shell(zsh, env | {"ZDOTDIR": str(effective)}, outside, effective, providers, interactive=False)
        if forbidden.exists():
            raise RuntimeError("Startup attempted installation or generation: " + forbidden.read_text())
        print(f"Native zsh smoke passed: {target}; pinned Prezto modules and {', '.join(providers)} completions")


if __name__ == "__main__":
    main()
