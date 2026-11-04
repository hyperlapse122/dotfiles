#!/usr/bin/env python3
"""Import encrypted GitHub tokens and restore native-keyring authentication."""

import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import sys
import urllib.request

import auth_common as common


def import_token(source, config, token_file):
    source = common.repository_root(source)
    token = common.read_token(token_file)
    intended = common.read_secrets(source, config)
    github = intended.setdefault("github", {})
    if not isinstance(github, dict):
        raise common.AuthError("Existing GitHub secrets must contain a mapping.")
    github["token"] = token
    common.publish_secrets(source, config, intended, token_file)


HOSTS = ("github.com", "gist.github.com")


def private_environment():
    env = os.environ.copy()
    for name in list(env):
        if (name.startswith(("KEYRING_PROPERTY_", "GIT_TRACE"))
                or name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN",
                            "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG", "GIT_CURL_VERBOSE",
                            "PYTHON_KEYRING_BACKEND", "PYTHONPATH", "KEYCHAIN_PATH")):
            env.pop(name)
    env["GH_PROMPT_DISABLED"] = "1"
    return env


def gh_config_directory():
    if os.environ.get("GH_CONFIG_DIR"):
        return Path(os.environ["GH_CONFIG_DIR"])
    if os.environ.get("XDG_CONFIG_HOME"):
        return Path(os.environ["XDG_CONFIG_HOME"]) / "gh"
    if os.name == "nt" and os.environ.get("APPDATA"):
        return Path(os.environ["APPDATA"]) / "GitHub CLI"
    return Path.home() / ".config/gh"


def github_login(token):
    request = urllib.request.Request(
        "https://api.github.com/user",
        headers={"Authorization": "Bearer " + token, "User-Agent": "dotfiles-github-auth",
                 "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            login = json.load(response).get("login")
        if not isinstance(login, str) or not login:
            raise ValueError()
        return login
    except Exception:
        raise common.AuthError("Cannot identify the GitHub account; check token access and TLS trust.") from None




def apply_auth(source, config, destination):
    source = common.repository_root(source)
    gh = Path(destination) / ".local/bin" / ("gh.exe" if os.name == "nt" else "gh")
    keyring = shutil.which("keyring")
    if not gh.is_file() or not keyring:
        raise common.AuthError("Install personal gh and the mise-managed keyring tool before applying authentication.")
    common.require_encryption_policy(source, config)
    secrets = common.read_secrets(source, config)
    token = secrets.get("github", {}).get("token") if isinstance(secrets.get("github"), dict) else None
    if not isinstance(token, str) or not token or "\n" in token or "\r" in token:
        raise common.AuthError("Import a nonempty GitHub token into encrypted source before applying authentication.")
    login = github_login(token)
    env = private_environment()
    metadata = gh_config_directory() / "hosts.yml"
    document = common.read_mapping(source, config, metadata)
    desired = copy.deepcopy(document)
    for host in HOSTS:
        if host == "gist.github.com" and host not in desired:
            # Gist is a Git credential alias, not an additional GitHub API host.
            # Do not register it in gh's host list solely to supply Git a PAT.
            continue
        record = desired.setdefault(host, {})
        if not isinstance(record, dict):
            raise common.AuthError("Managed GitHub CLI host metadata must contain a mapping.")
        users = record.setdefault("users", {})
        if not isinstance(users, dict):
            raise common.AuthError("Managed GitHub CLI account metadata must contain a mapping.")
        account = users.get(login) or {}
        if not isinstance(account, dict):
            raise common.AuthError("Managed GitHub CLI account metadata must contain a mapping.")
        users[login] = account
        for entry in (record, account):
            entry.pop("oauth_token", None)
            entry.pop("refresh_token", None)
        record["user"] = login
        record["git_protocol"] = "https"
    command = [keyring, "--keyring-path", str(source / "scripts"),
               "--keyring-backend", "cli_native.Keyring"]
    for host in HOSTS:
        for user in (login, ""):
            if common.native_get(command, "gh:" + host, user, env) != token:
                common.native_set(command, "gh:" + host, user, token, env)
            if common.native_get(command, "gh:" + host, user, env) != token:
                raise common.AuthError("Native credential verification failed.")
    if desired != document:
        common.publish_mapping(metadata, desired)
    for host in HOSTS:
        for flags in (["--user", login], []):
            actual = common.run_private([str(gh), "auth", "token", "--secure-storage", "--no-refresh",
             "--hostname", host, *flags], env=env,
            operation="GitHub CLI could not read the registered native credential.",).removesuffix("\n")
            if actual != token:
                raise common.AuthError("GitHub CLI native credential verification failed.")



def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    importer = commands.add_parser("import", help="Import a token into verified encrypted source")
    importer.add_argument("--source", type=Path, help="Repository root (defaults to this script's repository)")
    importer.add_argument("--config", type=Path, help="Existing initialized chezmoi configuration")
    importer.add_argument("--token-file", type=Path, required=True, help="Plaintext input removed after verification")
    applier = commands.add_parser("apply", help="Restore authentication in the native system keyring")
    applier.add_argument("--source", type=Path, help="Repository root")
    applier.add_argument("--config", type=Path, help="Existing initialized chezmoi configuration")
    applier.add_argument("--destination", type=Path, required=True, help="Chezmoi destination home")
    args = parser.parse_args(argv)
    try:
        if args.command == "import":
            import_token(common.repository_root(args.source), args.config, args.token_file)
        else:
            apply_auth(common.repository_root(args.source), args.config, args.destination)
    except common.AuthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print("GitHub authentication operation failed.", file=sys.stderr)
        return 1
    print("Encrypted token import verified; input file deleted." if args.command == "import"
          else "GitHub and Gist native authentication verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
