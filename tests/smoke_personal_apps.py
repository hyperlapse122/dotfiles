"""Run the committed personal CLI binaries in an OS-temporary chezmoi destination.

The default mode never runs PATH scripts. --path-integration is restricted to
GitHub-hosted disposable runners and restores the exact Windows user PATH.
"""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

from asset_fixtures import copy_asset_templates, run_with_assets

REPO = Path(__file__).resolve().parents[1]


def executable(name):
    found = shutil.which(name)
    if found is None:
        raise RuntimeError(f"Required executable is not on PATH: {name}")
    return str(Path(found).resolve())


def run(arguments, *, env, cwd):
    result = run_with_assets(
        arguments, env=env, cwd=cwd, capture_output=True, text=True,
        encoding="utf-8", errors="backslashreplace", timeout=300,
    )
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {arguments!r}\n"
            + result.stdout + result.stderr
        )
    return result.stdout.strip()


def check_version(output, tag):
    version = tag.removeprefix("rust-").removeprefix("v")
    if not re.search(r"(?<![\w.])v?" + re.escape(version) + r"(?![\w.])", output):
        raise RuntimeError(f"Expected pinned version {tag!r}, got {output!r}")


@contextmanager
def temporary_destination():
    root = tempfile.mkdtemp(prefix="personal apps native ")
    try:
        yield root
    finally:
        # Chezmoi's HTTP cache encodes presigned URLs into deeply nested paths.
        cleanup_root = "\\\\?\\" + root if os.name == "nt" else root
        def remove_readonly(function, path, error):
            if os.name != "nt" or function is not os.unlink or not isinstance(error, PermissionError):
                raise error
            mode = os.lstat(path).st_mode
            if not stat.S_ISREG(mode) or mode & stat.S_IWRITE:
                raise error
            # Git clone caches contain read-only pack files on Windows.
            os.chmod(path, mode | stat.S_IWRITE)
            function(path)

        shutil.rmtree(cleanup_root, onexc=remove_readonly)


@contextmanager
def windows_path_restored():
    import ctypes
    from ctypes import wintypes
    import winreg

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
        try:
            previous = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            previous = None
    try:
        yield
    finally:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_SET_VALUE) as key:
            if previous is None:
                try:
                    winreg.DeleteValue(key, "Path")
                except FileNotFoundError:
                    pass
            else:
                winreg.SetValueEx(key, "Path", 0, previous[1], previous[0])
        # Inform terminal hosts after restoring the original raw value and type.
        notify = ctypes.windll.user32.SendMessageTimeoutW
        notify.argtypes = [
            wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM,
            wintypes.UINT, wintypes.UINT, ctypes.POINTER(ctypes.c_size_t),
        ]
        notify.restype = wintypes.LPARAM
        result = ctypes.c_size_t()
        environment = ctypes.c_wchar_p("Environment")
        notify(0xFFFF, 0x1A, 0, ctypes.cast(environment, ctypes.c_void_p).value,
               0x2, 5000, ctypes.byref(result))


def fresh_windows_environment(isolated):
    import winreg

    def values(hive, path):
        with winreg.OpenKey(hive, path) as key:
            return {
                name.upper(): value
                for name, value, kind in (
                    winreg.EnumValue(key, index)
                    for index in range(winreg.QueryInfoKey(key)[1])
                )
                if kind in (winreg.REG_SZ, winreg.REG_EXPAND_SZ)
            }

    machine = values(winreg.HKEY_LOCAL_MACHINE,
                     r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment")
    user = values(winreg.HKEY_CURRENT_USER, "Environment")
    env = {name.upper(): value for name, value in isolated.items()}
    env.update(machine)
    env.update(user)
    env["PATH"] = os.pathsep.join(part for part in (machine.get("PATH"), user.get("PATH")) if part)
    # Keep all smoke-owned home/config/state locations isolated even if a runner
    # has also declared one of them in its persistent environment.
    for name in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "ZDOTDIR"):
        env[name] = isolated[name]
    for name, value in isolated.items():
        if name.startswith("XDG_"):
            env[name] = value
    expanded = {
        name: re.sub(r"%([^%]+)%", lambda match: env.get(match[1].upper(), match[0]), value)
        for name, value in env.items()
    }
    # A machine-wide gh installation legitimately precedes the user's PATH.
    # Isolate competing installs in this child only; the managed directory
    # must still be discovered from the PATH action's real registry value.
    installed = Path(isolated["HOME"]) / ".local/bin"
    commands = [executable.name for executable in installed.glob("*.exe")]
    paths = []
    for entry in expanded["PATH"].split(os.pathsep):
        directory = Path(entry.strip('"'))
        if (entry and directory.is_dir() and not directory.samefile(installed)
                and any((directory / command).is_file() for command in commands)):
            continue
        paths.append(entry)
    expanded["PATH"] = os.pathsep.join(paths)
    return expanded


def check_terminal_path(home, outside, env, name, tag, shells):
    suffix = ".ps1" if name == "agy" else ".exe"
    installed = home / ".local/bin" / (name + suffix if os.name == "nt" else name)
    if os.name == "nt":
        output = run([
            shells["powershell"], "-NoProfile", "-Command",
            f"(Get-Command {name} -ErrorAction Stop).Source; "
            f"& {name} --version; if ($LASTEXITCODE -ne 0) {{ exit $LASTEXITCODE }}",
        ], env=fresh_windows_environment(env), cwd=outside)
        lines = output.splitlines()
        if not lines or not installed.samefile(lines[0]):
            raise RuntimeError(f"Fresh Windows child did not discover {installed}: {output}")
        check_version("\n".join(lines[1:]), tag)
        print("Fresh Windows child: " + output)
        return

    terminal_env = env.copy()
    terminal_env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for shell_name, shell in shells.items():
        for mode in ("-lc", "-ic"):
            output = run([shell, mode, f"command -v {name} && {name} --version"],
                         env=terminal_env, cwd=outside)
            lines = output.splitlines()
            if not lines or Path(lines[0]) != installed:
                raise RuntimeError(f"{shell_name} {mode} did not discover {installed}: {output}")
            check_version("\n".join(lines[1:]), tag)
            print(f"Fresh {shell_name} {mode}: {output}")


def check_windows_path_preservation(apply_and_check, home, env):
    import winreg

    env["CE_PATH_SMOKE_ROOT"] = str(home / "unrelated tools")
    env["CE_PATH_SMOKE_HOME"] = str(home)
    expandable = r"%CE_PATH_SMOKE_ROOT%\bin"
    equivalent = expandable + ';%CE_PATH_SMOKE_HOME%/.LOCAL/BIN/'
    cases = (
        (expandable, winreg.REG_EXPAND_SZ, False),
        (str(home / "literal tools"), winreg.REG_SZ, False),
        (equivalent, winreg.REG_EXPAND_SZ, True),
    )
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0,
                       winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE) as key:
        for case_index, (original, kind, already_present) in enumerate(cases):
            winreg.SetValueEx(key, "Path", 0, kind, original)
            apply_and_check(case_index)
            actual, actual_kind = winreg.QueryValueEx(key, "Path")
            if actual_kind != kind:
                raise RuntimeError("PATH integration changed the existing registry value kind")
            if already_present:
                if actual != original:
                    raise RuntimeError("PATH integration rewrote an equivalent existing entry")
            else:
                prefix = original + ";"
                appended = actual[len(prefix):]
                expected = os.path.normcase(str(home / ".local/bin"))
                if not actual.startswith(prefix) or os.path.normcase(os.path.normpath(appended)) != expected:
                    raise RuntimeError("PATH integration changed unrelated raw entries or appended the wrong directory")
            apply_and_check(case_index)
            if winreg.QueryValueEx(key, "Path") != (actual, actual_kind):
                raise RuntimeError("Repeated PATH integration changed the existing value")
    print("Windows PATH: expandable and literal entries, registry kinds, and equivalent-entry idempotence preserved")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path-integration", action="store_true",
                        help="Exercise persistent PATH actions on a disposable GitHub-hosted runner only")
    parser.add_argument("--expected-target", help="Require chezmoi's native OS/architecture to match this target")
    args = parser.parse_args()
    if args.path_integration and not (
        os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"
    ):
        parser.error("--path-integration requires a disposable GitHub-hosted runner")

    # Resolve tools before changing HOME or subprocess cwd; mise's tools remain
    # usable when this script was started with `mise exec -- python ...`.
    chezmoi = executable("chezmoi")
    shells = {}
    if args.path_integration:
        if os.name == "nt":
            shells["powershell"] = str(
                Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            )
        else:
            shells = {name: executable(name) for name in ("bash", "zsh") if shutil.which(name)}
            if not shells:
                raise RuntimeError("PATH smoke requires Bash or Zsh")

    lock = json.loads((REPO / "home/.chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))
    applications = json.loads((REPO / "home/.chezmoidata/personal-apps.json").read_text(encoding="utf-8"))["personalApps"]
    with temporary_destination() as scratch:
        root = Path(scratch)
        home = root / "home"
        outside = root / "unrelated cwd"
        source = root / "source"
        for directory in (home, outside, source, root / "config", root / "state"):
            directory.mkdir()
        for relative in (
            ".chezmoidata/personal-apps.json",
            ".chezmoidata/personal-app-lock.json",
            ".chezmoiignore",
            ".chezmoiremove",
            "dot_local/bin/executable_agy.tmpl",
            "dot_local/bin/agy.ps1.tmpl",
            "dot_config/dotfiles/path.sh",
            ".chezmoiscripts/run_onchange_after_10-personal-app-path.ps1.tmpl",
            ".chezmoiscripts/run_onchange_after_10-personal-app-path.sh.tmpl",
            ".chezmoitemplates/zsh-settings",
        ):
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / relative, destination)
        copy_asset_templates(source, ('personal-apps', 'codex-package'))
        config = root / "config/chezmoi.toml"
        config.write_text("", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "ZDOTDIR": str(home),
            "APPDATA": str(root / "config"), "LOCALAPPDATA": str(root / "local"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_CONFIG_DIRS": str(root / "system config"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
            "CODEX_HOME": str(home / ".codex"),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"),
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            "AGY_SKIP_DOWNLOAD": "1",
        })
        command = [
            chezmoi, "--config", str(config), "--source", str(source),
            "--destination", str(home), "--cache", str(root / "cache"),
            "--no-tty",
        ]
        target = run(command + ["--persistent-state", str(root / "state/chezmoi.boltdb"),
                                "execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}"],
                     env=env, cwd=outside)
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected native {args.expected_target}, got {target}")
        if not any(target in app["targets"] for app in applications.values()):
            raise RuntimeError(f"No declared personal application for native target {target}")

        def apply_and_check(case_index=0):
            # Separate initial-state cases, but preserve onchange history within each case.
            arguments = command + [
                "--persistent-state", str(root / "state" / f"chezmoi-{case_index}.boltdb"), "apply",
            ]
            if not args.path_integration:
                arguments.append("--exclude=scripts")
            run(arguments, env=env, cwd=outside)
            for name, application in applications.items():
                if target not in application["targets"]:
                    continue
                tag = lock["personalAppLocks"][name]["tag"]
                binary = home / application.get("installDirectory", ".local/bin") / (application["command"] + ".exe" if os.name == "nt" else application["command"])
                output = run([str(binary), "--version"], env=env, cwd=outside)
                check_version(output, tag)
                print(f"Native {target}, {name}, committed {tag}: {output}")
                if args.path_integration:
                    check_terminal_path(home, outside, env, application["command"], tag, shells)

        if args.path_integration and os.name == "nt":
            with windows_path_restored():
                check_windows_path_preservation(apply_and_check, home, env)
        else:
            apply_and_check()


if __name__ == "__main__":
    main()
