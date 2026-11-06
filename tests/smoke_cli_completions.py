"""Prove the pinned Bash asset and managed startup with the real native CLI."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]


def execute(arguments, environment, *, input=""):
    result = subprocess.run(arguments, env=environment, input=input, capture_output=True,
                            text=True, encoding="utf-8", timeout=120)
    if result.returncode:
        raise RuntimeError(f"Native completion command failed: {result.stdout}{result.stderr}")
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="native Bash completion owner's ") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        environment = os.environ.copy()
        for name in ("BASH_ENV", "ENV"):
            environment.pop(name, None)
        environment.update(HOME=str(home), USERPROFILE=str(home),
                           XDG_CONFIG_HOME=str(root / "config"),
                           XDG_CACHE_HOME=str(root / "cache"),
                           XDG_DATA_HOME=str(root / "data"),
                           XDG_STATE_HOME=str(root / "state"),
                           GNUPGHOME=str(root / "unused-gnupg"),
                           BASH_COMPLETION_USER_FILE=str(root / "absent"),
                           BASH_COMPLETION_COMPAT_DIR=str(root / "absent"))
        config = root / "chezmoi.toml"
        config.write_text("", encoding="utf-8")
        chezmoi = shutil.which("chezmoi")
        render = [chezmoi, "--source", str(REPO), "--destination", str(home),
                  "--config", str(config), "execute-template"]
        template = (REPO / "home/.chezmoitemplates/external-assets/cli-completions.toml.tmpl").read_text()
        wrapper = ('{{ template "assets" (dict "chezmoi" (dict "os" "linux") '
                   '"cliCompletionAssets" .cliCompletionAssets) }}{{ define "assets" }}'
                   + template + '{{ end }}')
        manifest = root / "assets.toml"
        manifest.write_text(execute(render, environment, input=wrapper).stdout, encoding="utf-8")
        roots = root / "roots.tsv"
        roots.write_text(".local/share/dotfiles/bash-completion\tdirectory\ttrue\n", encoding="utf-8")
        prepare = ["sh", str(REPO / "scripts/prepare-external-assets.sh"),
                   str(manifest), str(roots), str(home), str(root / "asset-cache"), chezmoi]
        execute(prepare, environment)
        warm = execute(prepare, environment)
        if "Reusing prepared external assets" not in warm.stdout:
            raise RuntimeError("The pinned completion asset did not reuse shared preparation")

        binary = home / ".local/bin/dotfiles-pinentry"
        binary.parent.mkdir(parents=True)
        shutil.copy2(REPO / "target/release/dotfiles-pinentry", binary)
        execute([sys.executable, str(REPO / "scripts/cli-completions.py"),
                 "--destination", str(home), "--usage", shutil.which("usage")], environment)
        startup = execute(render + ["--with-stdin", (REPO / "home/modify_dot_bashrc").read_text()],
                          environment, input="# disposable native completion fixture\n")
        bashrc = home / ".bashrc"
        bashrc.write_text(startup.stdout, encoding="utf-8")
        script = ('complete -p dotfiles-pinentry; '
                  'printf "library=%s.%s.%s\\n" "${BASH_COMPLETION_VERSINFO[@]}"; '
                  'COMP_WORDS=(dotfiles-pinentry f); COMP_CWORD=1; '
                  'COMP_LINE="dotfiles-pinentry f"; COMP_POINT=${#COMP_LINE}; '
                  '_dotfiles_pinentry; printf "%s\\n" "${COMPREPLY[@]}"')
        result = execute(["bash", "--noprofile", "--rcfile", str(bashrc), "-i", "-c", script],
                         environment)
        if not any("-F _dotfiles_pinentry dotfiles-pinentry" in line
                   for line in result.stdout.splitlines()):
            raise RuntimeError("Managed Bash startup did not register the native CLI completion")
        if "library=2.18.0" not in result.stdout.splitlines():
            raise RuntimeError("Managed Bash startup did not load the pinned completion library")
        if "forget" not in result.stdout.splitlines():
            raise RuntimeError("The real native CLI did not complete through managed Bash startup")
        print("Pinned Bash preparation, warm reuse, managed startup, and native completion passed")


if __name__ == "__main__":
    main()
