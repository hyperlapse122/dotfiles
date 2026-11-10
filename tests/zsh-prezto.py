"""Exercise materialized Home Manager shell files with their built profile."""

import errno
import json
import os
from pathlib import Path
import pty
import pwd
import re
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time


def interactive(zsh, arguments, code, env, trace=False):
    pid, terminal = pty.fork()
    if pid == 0:
        os.execve(zsh, [zsh, *arguments, code], env)
    output = bytearray()
    deadline = time.monotonic() + 30
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.killpg(pid, signal.SIGKILL)
                raise AssertionError("interactive shell timed out")
            ready, _, _ = select.select([terminal], [], [], remaining)
            if not ready:
                continue
            try:
                chunk = os.read(terminal, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
    finally:
        os.close(terminal)
        _, status = os.waitpid(pid, 0)
    text = output.decode(errors="replace").replace("\r", "")
    assert os.waitstatus_to_exitcode(status) == 0, text[-8000:]
    # Terminal-title control sequences are normal; diagnostic text is not.
    text = re.sub(r"\x1b\][^\x07]*(?:\x07|\x1b\\)", "", text)
    if trace:
        loads = re.findall(r"(?m)^\+[^\n]*> source [^\n]*/share/zsh-prezto/init\.zsh$", text)
        assert len(loads) == 1, f"Prezto initialized {len(loads)} times"
        return
    assert text.count("SHELL_PARITY_OK") == 1, text
    assert not text.partition("SHELL_PARITY_OK")[0].strip(), text


def check(entry):
    assert entry["home"] and entry["profile"] and entry["files"], "missing materialized shell profile"
    with tempfile.TemporaryDirectory(prefix="zsh-parity-") as temporary:
        home = Path(temporary)
        dotdir = home / ".config/zsh"
        dotdir.mkdir(parents=True)
        session_vars = home / "session-vars.sh"
        session_vars.write_text(Path(entry["sessionVars"]).read_text().replace(entry["home"], temporary))
        for name in [".zshenv", ".zprofile", ".zshrc", ".zpreztorc", ".zlogin", ".zlogout"]:
            source = Path(entry["files"]) / ".config/zsh" / name
            content = source.read_text().replace(entry["home"], temporary)
            content = content.replace(entry["sessionVars"], str(session_vars))
            (dotdir / name).write_text(content)
        bridge = (Path(entry["files"]) / ".zshenv").read_text().replace(entry["home"], temporary)
        (home / ".zshenv").write_text(bridge)
        (home / ".zshrc").write_text("export PARITY_OLD_ROOT_RC=1\n")
        (home / ".gnupg").mkdir(mode=0o700)
        # Avoid starting an agent; this is also one of the real SSH guard cases.
        (home / ".gnupg/gpg-agent.conf").write_text("enable-ssh-support\n")
        local_bin = home / ".local/bin"
        local_bin.mkdir(parents=True)
        agent = local_bin / "gpg-agent"
        agent.write_text(f"#!{entry['bash']}\n"
                         'touch "$HOME/gpg-agent-called"\n'
                         "printf 'GPG_AGENT_INFO=parity-agent:0:1; export GPG_AGENT_INFO\\n'\n")
        agent.chmod(0o755)
        env = {
            "HOME": temporary,
            "PATH": entry["profile"] + "/bin:" + os.environ["PATH"]
                    + (":/usr/bin:/bin:/usr/sbin:/sbin" if entry["kind"] == "darwin" else ""),
            "TERM": "xterm-256color",
            "LANG": entry["locale"],
            "LC_ALL": entry["locale"],
            "LOGNAME": pwd.getpwuid(os.getuid()).pw_name,
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "XDG_STATE_HOME": str(home / ".local/state"),
            "SSH_AUTH_SOCK": str(home / "existing-agent.sock"),
            "PARITY_PROFILE_BIN": entry["profile"] + "/bin",
        }
        code = r'''
          fail() { print -r -- "FAIL: $*"; exit 1; }
          (( $+functions[pmodload] )) || fail 'Prezto did not initialize'
          [[ -z ${PARITY_OLD_ROOT_RC-} ]] || fail 'old root zshrc was unexpectedly sourced'
          (( $+functions[prompt_sorin_setup] )) || fail 'sorin did not load'
          [[ $(bindkey '^A') == *beginning-of-line* ]] || fail 'emacs bindings missing'
          for cmd in codex gh glab ghq mise usage; do
            [[ ${_comps[$cmd]-} == _$cmd ]] || fail "completion missing for $cmd"
            (( $+functions[_$cmd] )) || fail "completion function missing for $cmd"
          done
          zstyle -a ':prezto:load' pmodule parity_modules
          (( $parity_modules[(i)utility] < $parity_modules[(i)git] )) || fail 'utility must precede git'
          zstyle -t ':prezto:*:*' color || fail 'color disabled'
          [[ $NODE_USE_SYSTEM_CA == 1 ]] || fail 'system CA environment missing'
          (( $path[(i)$HOME/.local/bin] < $path[(i)$PARITY_PROFILE_BIN] )) || fail 'local bin lost precedence'
          [[ $HISTFILE == $HOME/.local/state/zsh/history ]] || fail 'wrong history path'
          [[ $HISTSIZE == 10000 && $SAVEHIST == 10000 ]] || fail 'wrong history limits'
          [[ -o extendedhistory && -o histignoredups && -o sharehistory ]] || fail 'history options missing'
          [[ -o histignorealldups && -o histsavenodups && -o histfindnodups && -o histexpiredupsfirst ]] || fail 'Prezto duplicate history behavior was overridden'
          (( $+functions[_mise_hook] )) || fail 'mise was not activated'
          [[ $GPG_TTY == $TTY && -n $TTY ]] || fail 'wrong GPG_TTY'
          [[ $SSH_AUTH_SOCK == $HOME/existing-agent.sock ]] || fail 'SSH agent changed'
          [[ $parity_modules[(Ie)gpg] == 0 ]] || fail 'GPG SSH guard ignored'
          print -s -- parity-history-sentinel
          print -r -- SHELL_PARITY_OK
        '''
        for mode in ["-ic", "-ilc"]:
            interactive(entry["profile"] + "/bin/zsh", [mode], code, env)
            history = home / ".local/state/zsh/history"
            assert "parity-history-sentinel" in history.read_text(), "history was not saved"
            interactive(entry["profile"] + "/bin/zsh", [mode.replace("-", "-x")], code, env, trace=True)
        # The cached environment is an independent SSH guard, not the config guard.
        (home / ".gnupg/gpg-agent.conf").write_text("")
        cached = home / ".cache/prezto/gpg-agent.env"
        cached.parent.mkdir(parents=True, exist_ok=True)
        cached.write_text("export SSH_AUTH_SOCK=wrong-agent.sock\n")
        interactive(entry["profile"] + "/bin/zsh", ["-ic"], code, env)
        cached.unlink()
        allowed = code.replace("[[ $parity_modules[(Ie)gpg] == 0 ]]", "(( $parity_modules[(Ie)gpg] > 0 ))")
        interactive(entry["profile"] + "/bin/zsh", ["-ic"], allowed, env)
        assert (home / "gpg-agent-called").is_file(), "GPG module did not call the isolated stub"
        bashrc = (Path(entry["files"]) / ".bashrc").read_text().replace(entry["home"], temporary)
        (home / ".bashrc").write_text(bashrc.replace(entry["sessionVars"], str(session_vars)))
        interactive(entry["bash"], ["-ic"], r'''
          COMP_WORDS=(parity-tool --option)
          COMP_CWORD=1
          COMP_LINE='parity-tool --option'
          COMP_POINT=${#COMP_LINE}
          check_completion() {
            local cur prev words cword
            _init_completion || return 1
            [[ $cur == --option ]]
          }
          check_completion || { echo 'Bash completion initialization failed'; exit 1; }
          echo SHELL_PARITY_OK
        ''', env)
        # Evaluate the actual generated module selection with a minimal command path.
        commands = home / "commands"
        commands.mkdir()
        grep = shutil.which("grep")
        (commands / "grep").symlink_to(grep)
        selection = r'''
          path=("$1")
          source "$2"
          zstyle -a ':prezto:load' pmodule chosen
          print -r -- "${(j: :)chosen}"
        '''
        for available in [False, True]:
            if available:
                for command in ["git", "brew", "gpg-agent"]:
                    (commands / command).symlink_to(grep)
            for guarded in [False, True]:
                cached.unlink(missing_ok=True)
                (home / ".gnupg/gpg-agent.conf").write_text("enable-ssh-support\n" if guarded else "")
                result = subprocess.run(
                    [entry["profile"] + "/bin/zsh", "-dfc", selection, "zsh", str(commands), str(dotdir / ".zpreztorc")],
                    env=env, text=True, capture_output=True, check=True,
                )
                assert not result.stderr, result.stderr
                selected = result.stdout.split()
                assert ("git" in selected) == available, selected
                assert ("homebrew" in selected) == (available and entry["kind"] == "darwin"), selected
                assert ("gpg" in selected) == (available and not guarded), selected


def check_migration(entry):
    files = Path(entry["files"])
    assert not (files / ".zshrc").exists(), "root .zshrc ownership changed"
    for name in [".zshenv", ".config/zsh/.zshenv", ".config/zsh/.zshrc", ".zshrc"]:
        with tempfile.TemporaryDirectory(prefix="shell-collision-") as temporary:
            home = Path(temporary)
            generation = home / "generation"
            generation.mkdir()
            (generation / "home-files").symlink_to(files)
            target = home / name
            target.parent.mkdir(parents=True, exist_ok=True)
            original = b"# unrelated owner content\nexport OWNER_CUSTOM=preserve-me\n"
            target.write_bytes(original)
            env = {"HOME": temporary, "PATH": os.environ["PATH"],
                   "newGenPath": str(generation), "LC_ALL": entry["locale"],
                   "HOME_MANAGER_BACKUP_EXT": "", "HOME_MANAGER_BACKUP_COMMAND": ""}
            command = [entry["bash"], entry["collisionCheck"]]
            result = subprocess.run(command, env=env, text=True, capture_output=True)
            assert target.read_bytes() == original, f"collision check changed {name}"
            if name == ".zshrc":
                assert result.returncode == 0, result.stdout + result.stderr
            else:
                assert result.returncode != 0, f"activation would clobber {name}"
                assert "would be clobbered" in result.stdout + result.stderr, result.stdout + result.stderr
                target.write_bytes((files / name).read_bytes())
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                assert result.returncode == 0, result.stdout + result.stderr
                target.unlink()
                target.symlink_to(files / name)
                result = subprocess.run(command, env=env, text=True, capture_output=True)
                assert result.returncode == 0, result.stdout + result.stderr
                target.unlink()
                target.write_bytes(original)
            assert target.read_bytes() == original, f"activation changed owner content in {name}"


entries = json.loads(Path(sys.argv[1]).read_text())
assert entries, "no shell profiles to check"
assert any(entry["bootstrap"] for entry in entries), "no bootstrap shell profile"
assert any(not entry["bootstrap"] for entry in entries), "no production shell profile"
for entry in entries:
    try:
        check(entry)
        check_migration(entry)
    except Exception as error:
        raise AssertionError(f"{entry['name']}: {error}") from error
    print(f"{entry['name']}: interactive shell passed")
