#!/usr/bin/env python3
"""Import encrypted GitLab connection data and reconcile native authentication."""

import argparse
import copy
import ctypes
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import urllib.request
import uuid

import auth_common as common


def hostname(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", value):
        raise common.AuthError("Connection metadata must contain valid DNS hostnames.")
    value = value.lower()
    if any(not label or len(label) > 63 or label.startswith("-") or label.endswith("-")
           for label in value.split(".")):
        raise common.AuthError("Connection metadata must contain valid DNS hostnames.")
    return value


def connection_values(document, *, require_user=False):
    if not isinstance(document, dict):
        raise common.AuthError("GitLab connection metadata must contain a mapping.")
    result = {key: hostname(document.get(key)) for key in ("host", "registry")}
    user = document.get("user")
    if user is not None:
        if not isinstance(user, str) or not user or any(c in user for c in "\r\n\0"):
            raise common.AuthError("GitLab account metadata must contain a valid username.")
        result["user"] = user
    elif require_user:
        raise common.AuthError("Import GitLab account metadata before applying authentication.")
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Authentication headers must not follow a redirect to another origin.
        return None


def gitlab_user(host, token):
    request = urllib.request.Request(
        "https://" + hostname(host) + "/api/v4/user",
        headers={"PRIVATE-TOKEN": token, "User-Agent": "dotfiles-gitlab-auth"},
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            user = json.load(response).get("username")
        if not isinstance(user, str) or not user or any(c in user for c in "\r\n\0"):
            raise ValueError()
        return user
    except Exception:
        raise common.AuthError("Cannot identify the GitLab account; check token access and TLS trust.") from None


def import_token(source, config, token_file, connection_file):
    source = common.repository_root(source)
    token_file, connection_file = Path(token_file), Path(connection_file)
    target = common.source_directory(source) / ".secrets/api-tokens.yaml.asc"
    for other in (target, connection_file):
        if token_file.resolve() == other.resolve() or (
                token_file.exists() and other.exists() and os.path.samefile(token_file, other)):
            raise common.AuthError("Token input must be separate from metadata and encrypted source.")
    try:
        connection = connection_values(json.loads(connection_file.read_text(encoding="utf-8-sig")))
    except common.AuthError:
        raise
    except (OSError, ValueError, UnicodeError):
        raise common.AuthError("Cannot read the local GitLab connection file.") from None
    token = common.read_token(token_file)
    desired = common.read_secrets(source, config)
    record = desired.setdefault("gitlab", {})
    if not isinstance(record, dict):
        raise common.AuthError("Existing GitLab secrets must contain a mapping.")
    if "user" not in connection:
        connection["user"] = gitlab_user(connection["host"], token)
    record.update(connection)
    record["token"] = token
    common.publish_secrets(source, config, desired, token_file)


def windows_known_folder(identifier, env_names, fallback):
    # adrg/xdg prefers Windows Known Folders over environment overrides.
    folder_id = (ctypes.c_ubyte * 16).from_buffer_copy(
        uuid.UUID(identifier).bytes_le)
    value = ctypes.c_wchar_p()
    shell = ctypes.WinDLL("shell32")
    shell.SHGetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                         ctypes.c_void_p, ctypes.POINTER(ctypes.c_wchar_p)]
    shell.SHGetKnownFolderPath.restype = ctypes.c_long
    for flags in (0x4000, 0x4400):  # DONT_VERIFY, then DEFAULT_PATH | DONT_VERIFY.
        if shell.SHGetKnownFolderPath(ctypes.byref(folder_id), flags, None, ctypes.byref(value)) == 0:
            try:
                return Path(value.value)
            finally:
                ole = ctypes.WinDLL("ole32")
                ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
                ole.CoTaskMemFree(value)
    return Path(next((os.environ[name] for name in env_names if os.environ.get(name)), fallback))


def xdg_path(value):
    if not value:
        return None
    if sys.platform == "win32":
        if value.startswith("%USERPROFILE%"):
            home = windows_known_folder(
                "5e6c858f-0e22-4760-9afe-ea3317b67173", ("USERPROFILE",), Path.home())
            value = str(home / value[13:].lstrip("/\\"))
    elif value.startswith(("~", "$HOME")):
        value = str(Path.home() / value[1 if value.startswith("~") else 5:].lstrip("/"))
    path = Path(value)
    return path if path.is_absolute() else None


def glab_config_directory():
    if os.environ.get("GLAB_CONFIG_DIR"):
        return Path(os.environ["GLAB_CONFIG_DIR"])
    legacy = Path.home() / ".config/glab-cli"
    if (legacy / "config.yml").is_file():
        return legacy
    xdg = xdg_path(os.environ.get("XDG_CONFIG_HOME"))
    if xdg:
        return xdg / "glab-cli"
    if sys.platform == "win32":
        base = windows_known_folder(
            "f1b32785-6fba-4fcf-9d55-7b8e7f157091", ("LOCALAPPDATA",), Path.home() / "AppData/Local")
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support"
    else:
        base = Path.home() / ".config"
    return base / "glab-cli"


def glab_config_source(metadata):
    if os.environ.get("GLAB_CONFIG_DIR") or metadata.exists():
        return metadata
    directories = [path for value in os.environ.get("XDG_CONFIG_DIRS", "").split(os.pathsep)
                   if (path := xdg_path(value)) is not None]
    if not directories:
        if sys.platform == "win32":
            directories = [
                windows_known_folder("62ab5d82-fdc1-4dc3-a9dd-070d1d495d97",
                                     ("ProgramData", "ALLUSERSPROFILE"),
                                     Path(Path.home().anchor) / "ProgramData"),
                windows_known_folder("3eb685db-65f9-4cf6-a03a-e3ef65729f3d",
                                     ("APPDATA",), Path.home() / "AppData/Roaming"),
            ]
        elif sys.platform == "darwin":
            directories = [Path.home() / "Library/Preferences", Path("/Library/Application Support"),
                           Path("/Library/Preferences"), Path.home() / ".config"]
        else:
            directories = [Path("/etc/xdg")]
    # glab reads one global document, but always persists to its writable user directory.
    for directory in directories:
        candidate = directory / "glab-cli/config.yml"
        if candidate.exists():
            return candidate
    return metadata


def private_environment():
    env = os.environ.copy()
    for name in list(env):
        if (name.startswith(("GITLAB_", "GLAB_", "GIT_TRACE", "KEYRING_PROPERTY_"))
                and name != "GLAB_CONFIG_DIR") or name in (
                    "GL_HOST", "OAUTH_TOKEN", "API_PROTOCOL", "GIT_PROTOCOL", "USE_KEYRING",
                    "IS_OAUTH2", "CI", "CI_JOB_TOKEN", "DEBUG", "DEBUG_HTTP", "GIT_CURL_VERBOSE",
                    "PYTHON_KEYRING_BACKEND", "PYTHONPATH", "KEYCHAIN_PATH"):
            env.pop(name)
    env.update({"GLAB_NO_PROMPT": "true", "GLAB_CHECK_UPDATE": "false",
                "GLAB_SHOW_WHATS_NEW": "false", "GLAB_SEND_TELEMETRY": "false"})
    return env


def desired_config(document, host, user):
    desired = copy.deepcopy(document)
    hosts = desired.setdefault("hosts", {})
    if not isinstance(hosts, dict):
        raise common.AuthError("GitLab CLI hosts must contain a mapping.")
    # glab reads scalar node text: serialized null becomes the string "null",
    # not the empty value represented by an unset YAML setting.
    for settings in (desired, *hosts.values()):
        if isinstance(settings, dict):
            for key, value in settings.items():
                if value is None:
                    settings[key] = ""
    record = hosts.setdefault(host, {})
    if not isinstance(record, dict):
        raise common.AuthError("Managed GitLab CLI metadata must contain a mapping.")
    for key in ("token", "gitlab_token", "oauth_token", "job_token",
                "oauth2_refresh_token", "oauth2_expiry_date"):
        record.pop(key, None)
    record.update({"user": user, "use_keyring": "true", "is_oauth2": "false",
                   "api_protocol": "https", "api_host": host, "subfolder": "/",
                   "skip_tls_verify": "false"})
    return desired


def git_include(host, glab):
    executable = shlex.quote(str(glab).replace("\\", "/"))
    helper = "!" + executable + " auth git-credential"
    return ('[credential ' + json.dumps("https://" + host, ensure_ascii=False) + ']\n'
            '    helper =\n    helper = ' + json.dumps(helper, ensure_ascii=False) + '\n')


def verify_credential(glab, host, user, token, env, destination):
    result = common.run_private(
        [str(glab), "auth", "git-credential", "get"],
        input="protocol=https\nhost=" + host + "\n\n", env=env, cwd=destination,
        operation="GitLab CLI could not read the registered native credential.",
    )
    fields = dict(line.split("=", 1) for line in result.splitlines() if "=" in line)
    if fields.get("username") != user or fields.get("password") != token:
        raise common.AuthError("GitLab CLI native credential verification failed.")


def apply_auth(source, config, destination):
    source, destination = common.repository_root(source), Path(destination)
    glab = destination / ".local/bin" / ("glab.exe" if os.name == "nt" else "glab")
    keyring = shutil.which("keyring")
    if not glab.is_file() or not keyring:
        raise common.AuthError("Install personal glab and the mise-managed keyring tool before applying authentication.")
    secrets = common.read_secrets(source, config)
    record = secrets.get("gitlab")
    connection = connection_values(record, require_user=True)
    token = record.get("token")
    if not isinstance(token, str) or not token or any(c in token for c in "\r\n\0"):
        raise common.AuthError("Import a nonempty GitLab token before applying authentication.")
    host, user = connection["host"], connection["user"]
    if gitlab_user(host, token) != user:
        raise common.AuthError("GitLab token account does not match encrypted account metadata.")
    env = private_environment()
    metadata = glab_config_directory().resolve() / "config.yml"
    active_metadata = glab_config_source(metadata)
    env["GLAB_CONFIG_DIR"] = str(metadata.parent)
    document = common.read_mapping(source, config, active_metadata)
    desired = desired_config(document, host, user)
    command = [keyring, "--keyring-path", str(source / "scripts"),
               "--keyring-backend", "cli_native.Keyring"]
    service = "glab:" + host + ":token"
    if common.native_get(command, service, "", env) != token:
        common.native_set(command, service, "", token, env)
    if common.native_get(command, service, "", env) != token:
        raise common.AuthError("Native GitLab credential verification failed.")
    if desired != document or active_metadata != metadata:
        common.publish_mapping(metadata, desired)
    verify_credential(glab, host, user, token, env, destination)
    common.publish_text(destination / ".local/share/dotfiles/gitlab.gitconfig", git_include(host, glab))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    importer = commands.add_parser("import", help="Import private GitLab data into encrypted source")
    importer.add_argument("--token-file", type=Path, required=True,
                          help="Plaintext token input removed after verified encrypted publication")
    importer.add_argument("--connection-file", type=Path, required=True,
                          help="Confidential local JSON containing host, registry, and optional user")
    applier = commands.add_parser("apply", help="Reconcile native GitLab and Git HTTPS authentication")
    applier.add_argument("--destination", type=Path, required=True)
    for command in (importer, applier):
        command.add_argument("--source", type=Path, help="Repository root")
        command.add_argument("--config", type=Path, help="Existing initialized chezmoi configuration")
    args = parser.parse_args(argv)
    try:
        if args.command == "import":
            import_token(args.source, args.config, args.token_file, args.connection_file)
        else:
            apply_auth(args.source, args.config, args.destination)
    except common.AuthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("GitLab authentication operation failed; private output withheld.", file=sys.stderr)
        return 1
    print("Encrypted GitLab import verified; token input deleted." if args.command == "import"
          else "GitLab native credential and Git HTTPS helper verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
