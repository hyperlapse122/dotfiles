"""Exercise materialized Home Manager shell files with their built profile."""

import errno
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import sys
import tempfile
import time


def interactive(zsh, arguments, code, env):
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
                raise AssertionError("interactive zsh timed out")
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
    assert os.waitstatus_to_exitcode(status) == 0, text
    # Terminal-title control sequences are normal; diagnostic text is not.
    text = re.sub(r"\x1b\][^\x07]*(?:\x07|\x1b\\)", "", text)
    assert text.count("SHELL_PARITY_OK") == 1, text
    assert not text.partition("SHELL_PARITY_OK")[0].strip(), text


def check(entry):
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
        (home / ".gnupg").mkdir(mode=0o700)
        # Avoid starting an agent; this is also one of the real SSH guard cases.
        (home / ".gnupg/gpg-agent.conf").write_text("enable-ssh-support\n")
        env = {
            "HOME": temporary,
            "PATH": entry["profile"] + "/bin:" + os.environ["PATH"],
            "TERM": "xterm-256color",
            "LOGNAME": os.environ.get("USER", "nixbld"),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "XDG_STATE_HOME": str(home / ".local/state"),
            "SSH_AUTH_SOCK": str(home / "existing-agent.sock"),
        }
        code = r'''
          fail() { print -r -- "FAIL: $*"; exit 1; }
          (( $+functions[pmodload] )) || fail 'Prezto did not initialize'
          (( $+functions[prompt_sorin_setup] )) || fail 'sorin did not load'
          [[ $(bindkey '^A') == *beginning-of-line* ]] || fail 'emacs bindings missing'
          for cmd in codex gh glab ghq mise usage; do
            [[ ${_comps[$cmd]-} == _$cmd ]] || fail "completion missing for $cmd"
            (( $+functions[_$cmd] )) || fail "completion function missing for $cmd"
          done
          print -r -- SHELL_PARITY_OK
        '''
        for mode in ["-ic", "-ilc"]:
            interactive(entry["profile"] + "/bin/zsh", [mode], code, env)


entries = json.loads(Path(sys.argv[1]).read_text())
assert entries, "no shell profiles to check"
for entry in entries:
    try:
        check(entry)
    except Exception as error:
        raise AssertionError(f"{entry['name']}: {error}") from error
    print(f"{entry['name']}: interactive shell passed")
