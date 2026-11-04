#!/usr/bin/env python3
"""Import encrypted GitHub tokens and restore native-keyring authentication."""

import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request


class AuthError(Exception):
    """An operator-facing failure containing only a fixed, value-free message."""


def run_private(argv, *, input=None, env=None, operation="Private command failed."):
    """Capture child output privately; callers supply a fixed diagnostic label.

    Secret input belongs on stdin, never in argv. Neither a child diagnostic nor
    a subprocess exception is safe to forward to the operator.
    """
    try:
        result = subprocess.run(
            argv, input="" if input is None else input, env=env,
            capture_output=True, text=True, encoding="utf-8", errors="strict", timeout=180,
        )
        if result.returncode != 0:
            raise AuthError(operation)
        return result.stdout
    except AuthError:
        raise
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise AuthError(operation) from None


def repository_root(source=None):
    """Select the script's repository unless an explicit repository is given."""
    try:
        root = Path(source).resolve() if source is not None else Path(__file__).resolve().parents[1]
        if not (root / ".chezmoiroot").is_file():
            raise AuthError("Repository source root is unavailable.")
        return root
    except (OSError, ValueError):
        raise AuthError("Repository source root is unavailable.") from None


def source_directory(source):
    """Resolve chezmoi's source subdirectory without changing global config."""
    root = repository_root(source)
    try:
        relative = Path((root / ".chezmoiroot").read_text(encoding="utf-8").strip())
        directory = (root / relative).resolve()
        if relative.is_absolute() or not directory.is_relative_to(root) or not directory.is_dir():
            raise AuthError("Repository chezmoi source directory is unavailable.")
        return directory
    except (OSError, UnicodeError, ValueError):
        raise AuthError("Repository chezmoi source directory is unavailable.") from None


def chezmoi_argv(source, config=None):
    """Bind every invocation to this repository, leaving initialized config alone."""
    root = repository_root(source)
    argv = ["chezmoi", "--source", str(source_directory(root)),
            "--working-tree", str(root), "--no-tty", "--no-pager"]
    if config is not None:
        argv.extend(["--config", str(Path(config).resolve())])
    return argv


def _private_json(argv, operation, *, input=None):
    try:
        return json.loads(run_private(argv, input=input, operation=operation))
    except (ValueError, TypeError):
        raise AuthError(operation) from None


def require_encryption_policy(source, config=None):
    """Require the existing repository-initialized, sole-recipient GPG policy."""
    argv = chezmoi_argv(source, config)
    effective = _private_json(argv + ["dump-config", "--format", "json"],
                              "Cannot read initialized encryption policy.")
    expected = _private_json(argv + [
        "execute-template",
        '{{ dict "recipient" .gpgRecipient "command" '
        '(includeTemplate "gpg-settings" . | fromJson).program | toJson }}',
    ], "Cannot read repository encryption policy.")
    if not isinstance(effective, dict) or not isinstance(expected, dict):
        raise AuthError("Repository encryption must be initialized before importing.")
    gpg = effective.get("gpg")
    if (effective.get("encryption") != "gpg" or not isinstance(gpg, dict)
            or not expected.get("recipient") or not expected.get("command")
            or gpg.get("recipient") != expected["recipient"]
            or gpg.get("command") != expected["command"]
            or gpg.get("recipients") not in (None, [])
            or gpg.get("symmetric") is not False
            or gpg.get("args") != ["--no-options", "--no-auto-check-trustdb"]):
        raise AuthError("Repository encryption must be initialized before importing.")
    return gpg


def read_secrets(source, config=None, *, ciphertext=None):
    """Stream GPG plaintext in memory, then parse it with chezmoi's YAML rules.

    Chezmoi's native GPG decrypt/encrypt commands create plaintext temp files.
    Reuse its validated policy, not that file-based transport, for this path.
    """
    gpg = require_encryption_policy(source, config)
    path = Path(ciphertext) if ciphertext is not None else source_directory(source) / ".secrets/api-tokens.yaml.asc"
    try:
        encrypted = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        raise AuthError("Cannot read the encrypted secrets document.") from None
    plaintext = run_private(
        [gpg["command"], *gpg["args"], "--decrypt"], input=encrypted,
        operation="Cannot decrypt the encrypted secrets document.",
    )
    document = _private_json(
        chezmoi_argv(source, config) + ["execute-template", "--with-stdin",
                                     "{{ .chezmoi.stdin | fromYaml | toJson }}"],
        "Cannot parse the encrypted secrets document.", input=plaintext,
    )
    if not isinstance(document, dict):
        raise AuthError("The encrypted secrets document must contain a mapping.")
    return document


def _read_token(token_file):
    try:
        token = Path(token_file).read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeError, ValueError):
        raise AuthError("Cannot read the token input file as UTF-8.") from None
    # Remove one conventional text-file line ending, not meaningful token bytes.
    if token.endswith("\r\n"):
        token = token[:-2]
    elif token.endswith(("\n", "\r")):
        token = token[:-1]
    if not token or "\n" in token or "\r" in token:
        raise AuthError("Token input must contain one nonempty line.")
    return token


def _verify_document(actual, expected):
    # Canonical JSON also distinguishes booleans from numbers, unlike dict ==.
    if json.dumps(actual, sort_keys=True, allow_nan=False) != json.dumps(
            expected, sort_keys=True, allow_nan=False):
        raise AuthError("Encrypted secrets verification failed.")


def import_token(source, config, token_file):
    """Publish a verified encrypted merge, then remove the original token file."""
    staged = None
    try:
        source = repository_root(source)
        token_file = Path(token_file)
        target = source_directory(source) / ".secrets/api-tokens.yaml.asc"
        # An input alias must never let the final unlink remove the ciphertext.
        if token_file.resolve() == target.resolve() or (
                token_file.exists() and target.exists() and os.path.samefile(token_file, target)):
            raise AuthError("Token input must be separate from encrypted source.")
        token = _read_token(token_file)
        gpg = require_encryption_policy(source, config)
        previous = read_secrets(source, config)
        intended = copy.deepcopy(previous)
        github = intended.setdefault("github", {})
        if not isinstance(github, dict):
            raise AuthError("Existing GitHub secrets must contain a mapping.")
        github["token"] = token
        encrypted = run_private(
            [gpg["command"], *gpg["args"], "--armor", "--recipient", gpg["recipient"], "--encrypt"],
            input=json.dumps(intended, ensure_ascii=False, allow_nan=False),
            operation="Token encryption failed.",
        )
        if (not encrypted.startswith("-----BEGIN PGP MESSAGE-----")
                or not encrypted.rstrip().endswith("-----END PGP MESSAGE-----")):
            raise AuthError("Token encryption did not produce armored ciphertext.")
        # Only encrypted content is ever staged, in the same directory so the
        # eventual publication is one atomic filesystem replacement.
        descriptor, name = tempfile.mkstemp(prefix=".api-tokens-", suffix=".asc", dir=target.parent)
        staged = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(encrypted)
        _verify_document(read_secrets(source, config, ciphertext=staged), intended)
        os.replace(staged, target)
        staged = None
        _verify_document(read_secrets(source, config), intended)
        try:
            token_file.unlink()
        except OSError:
            raise AuthError(
                "Encrypted source was published and verified, but token input deletion failed."
            ) from None
    except AuthError:
        raise
    except Exception:
        # Filesystem errors and decoding/comparison failures can contain values
        # from child processes or documents. Never expose their diagnostics.
        raise AuthError("Encrypted token import failed; token input was retained.") from None
    finally:
        if staged is not None:
            try:
                staged.unlink()
            except OSError:
                raise AuthError("Ciphertext staging cleanup failed; token input was retained.") from None

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
        return Path(os.environ["GH_CONFIG_DIR"]).expanduser()
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
        raise AuthError("Cannot identify the GitHub account; check token access and TLS trust.") from None


def native_get(command, host, user, env):
    try:
        result = subprocess.run(
            command + ["get", "gh:" + host, user], env=env, input="",
            capture_output=True, text=True, encoding="utf-8", timeout=120,
        )
        if result.returncode == 1:
            return None
        if result.returncode:
            raise AuthError("Cannot read the native credential store.")
        return result.stdout.removesuffix("\n")
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise AuthError("Cannot read the native credential store.") from None


def native_set(command, host, user, token, env):
    run_private(command + ["set", "gh:" + host, user], input=token, env=env,
                operation="Cannot write the native credential store; no plaintext fallback was used.")


def read_hosts(source, config, path):
    if not path.exists():
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
        encoded = run_private(
            chezmoi_argv(source, config) + ["execute-template", "--with-stdin",
                                         "{{ .chezmoi.stdin | fromYaml | toJson }}"],
            input=raw, operation="Cannot parse GitHub CLI account metadata.",
        )
        document = json.loads(encoded)
        if document is None:
            return {}
        if not isinstance(document, dict):
            raise ValueError()
        return document
    except (OSError, ValueError, UnicodeError):
        raise AuthError("Cannot read GitHub CLI account metadata.") from None


def publish_hosts(path, document):
    staged = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, name = tempfile.mkstemp(prefix=".hosts-", dir=path.parent)
        staged = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(staged, path)
        staged = None
    except (OSError, ValueError):
        raise AuthError("Cannot publish GitHub CLI account metadata.") from None
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def apply_auth(source, config, destination):
    source = repository_root(source)
    gh = Path(destination) / ".local/bin" / ("gh.exe" if os.name == "nt" else "gh")
    keyring = shutil.which("keyring")
    if not gh.is_file() or not keyring:
        raise AuthError("Install personal gh and the mise-managed keyring tool before applying authentication.")
    require_encryption_policy(source, config)
    secrets = read_secrets(source, config)
    token = secrets.get("github", {}).get("token") if isinstance(secrets.get("github"), dict) else None
    if not isinstance(token, str) or not token or "\n" in token or "\r" in token:
        raise AuthError("Import a nonempty GitHub token into encrypted source before applying authentication.")
    login = github_login(token)
    env = private_environment()
    metadata = gh_config_directory() / "hosts.yml"
    document = read_hosts(source, config, metadata)
    desired = copy.deepcopy(document)
    for host in HOSTS:
        if host == "gist.github.com" and host not in desired:
            # Gist is a Git credential alias, not an additional GitHub API host.
            # Do not register it in gh's host list solely to supply Git a PAT.
            continue
        record = desired.setdefault(host, {})
        if not isinstance(record, dict):
            raise AuthError("Managed GitHub CLI host metadata must contain a mapping.")
        users = record.setdefault("users", {})
        if not isinstance(users, dict):
            raise AuthError("Managed GitHub CLI account metadata must contain a mapping.")
        account = users.get(login) or {}
        if not isinstance(account, dict):
            raise AuthError("Managed GitHub CLI account metadata must contain a mapping.")
        users[login] = account
        for entry in (record, account):
            entry.pop("oauth_token", None)
            entry.pop("refresh_token", None)
        record["user"] = login
        record["git_protocol"] = "https"
    command = [keyring, "--keyring-path", str(source / "scripts"),
               "--keyring-backend", "gh_native.Keyring"]
    for host in HOSTS:
        for user in (login, ""):
            if native_get(command, host, user, env) != token:
                native_set(command, host, user, token, env)
            if native_get(command, host, user, env) != token:
                raise AuthError("Native credential verification failed.")
    if desired != document:
        publish_hosts(metadata, desired)
    for host in HOSTS:
        for flags in (["--user", login], []):
            actual = run_private(
                [str(gh), "auth", "token", "--secure-storage", "--no-refresh",
                 "--hostname", host, *flags], env=env,
                operation="GitHub CLI could not read the registered native credential.",
            ).removesuffix("\n")
            if actual != token:
                raise AuthError("GitHub CLI native credential verification failed.")



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
            import_token(repository_root(args.source), args.config, args.token_file)
        else:
            apply_auth(repository_root(args.source), args.config, args.destination)
    except AuthError as error:
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
