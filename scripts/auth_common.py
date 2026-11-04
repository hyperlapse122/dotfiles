import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


class AuthError(Exception):
    """An operator-facing failure containing only a fixed, value-free message."""


def run_private(argv, *, input=None, env=None, operation="Private command failed.", cwd=None):
    """Capture child output privately; callers supply a fixed diagnostic label.

    Secret input belongs on stdin, never in argv. Neither a child diagnostic nor
    a subprocess exception is safe to forward to the operator.
    """
    try:
        result = subprocess.run(
            argv, input="" if input is None else input, env=env, cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", errors="strict", timeout=180,
        )
        if result.returncode != 0:
            raise AuthError(operation)
        return result.stdout
    except AuthError:
        raise
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise AuthError(operation) from None


def repository_root(source=None):
    try:
        root = Path(source).resolve() if source is not None else Path(__file__).resolve().parents[1]
        if not (root / ".chezmoiroot").is_file():
            raise AuthError("Repository source root is unavailable.")
        return root
    except (OSError, ValueError):
        raise AuthError("Repository source root is unavailable.") from None


def source_directory(source):
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


def read_token(token_file):
    try:
        token = Path(token_file).read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeError, ValueError):
        raise AuthError("Cannot read the token input file as UTF-8.") from None
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


def publish_secrets(source, config, document, token_file):
    """Publish verified ciphertext; retain prior ciphertext on final readback failure."""
    staged = None
    recovery = None
    published = False
    try:
        source = repository_root(source)
        token_file = Path(token_file)
        target = source_directory(source) / ".secrets/api-tokens.yaml.asc"
        if token_file.resolve() == target.resolve() or (
                token_file.exists() and target.exists() and os.path.samefile(token_file, target)):
            raise AuthError("Token input must be separate from encrypted source.")
        gpg = require_encryption_policy(source, config)
        encrypted = run_private(
            [gpg["command"], *gpg["args"], "--armor", "--recipient", gpg["recipient"], "--encrypt"],
            input=json.dumps(document, ensure_ascii=False, allow_nan=False),
            operation="Token encryption failed.",
        )
        if (not encrypted.startswith("-----BEGIN PGP MESSAGE-----")
                or not encrypted.rstrip().endswith("-----END PGP MESSAGE-----")):
            raise AuthError("Token encryption did not produce armored ciphertext.")
        # Plaintext is only streamed in memory. Both temporary files contain
        # ciphertext and live beside the target for atomic publication.
        descriptor, name = tempfile.mkstemp(prefix=".api-tokens-", suffix=".asc", dir=target.parent)
        staged = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(encrypted)
        _verify_document(read_secrets(source, config, ciphertext=staged), document)
        descriptor, name = tempfile.mkstemp(
            prefix=".api-tokens-recovery-", suffix=".asc", dir=target.parent)
        recovery = Path(name)
        with os.fdopen(descriptor, "wb") as stream, target.open("rb") as previous:
            shutil.copyfileobj(previous, stream)
        os.replace(staged, target)
        published = True
        staged = None
        try:
            _verify_document(read_secrets(source, config), document)
        except Exception:
            raise AuthError(
                "Encrypted source verification failed after publication; token input and prior ciphertext recovery copy were retained."
            ) from None
        try:
            recovery.unlink()
            recovery = None
        except OSError:
            raise AuthError(
                "Encrypted source was published and verified, but recovery cleanup failed; token input was retained."
            ) from None
        try:
            token_file.unlink()
        except OSError:
            raise AuthError(
                "Encrypted source was published and verified, but token input deletion failed."
            ) from None
    except AuthError:
        raise
    except Exception:
        # Filesystem and child exceptions may contain confidential values.
        raise AuthError("Encrypted token import failed; token input was retained.") from None
    finally:
        for temporary in (staged, recovery if not published else None):
            if temporary is not None:
                try:
                    temporary.unlink()
                except OSError:
                    raise AuthError(
                        "Ciphertext staging cleanup failed; token input was retained."
                    ) from None


def native_get(command, service, user, env):
    try:
        result = subprocess.run(
            command + ["get", service, user], env=env, input="",
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", timeout=120,
        )
        if result.returncode == 1:
            return None
        if result.returncode:
            raise AuthError("Cannot read the native credential store.")
        return result.stdout.removesuffix("\n")
    except (OSError, subprocess.SubprocessError, UnicodeError):
        raise AuthError("Cannot read the native credential store.") from None


def native_set(command, service, user, token, env):
    run_private(command + ["set", service, user], input=token, env=env,
                operation="Cannot write the native credential store; no plaintext fallback was used.")


def read_mapping(source, config, path):
    try:
        try:
            raw = Path(path).read_text(encoding="utf-8")
        except FileNotFoundError:
            return {}
        encoded = run_private(
            chezmoi_argv(source, config) + ["execute-template", "--with-stdin",
                                         "{{ .chezmoi.stdin | fromYaml | toJson }}"],
            input=raw, operation="Cannot parse CLI metadata.",
        )
        document = json.loads(encoded)
        if document is None:
            return {}
        if not isinstance(document, dict):
            raise ValueError()
        return document
    except (OSError, ValueError, UnicodeError):
        raise AuthError("Cannot read CLI metadata.") from None


def publish_text(path, text):
    """Atomically publish local metadata, leaving an identical file untouched."""
    staged = None
    try:
        path = Path(path)
        try:
            if path.read_bytes() == text.encode("utf-8"):
                return
        except FileNotFoundError:
            pass
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, name = tempfile.mkstemp(prefix=".metadata-", dir=path.parent)
        staged = Path(name)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.replace(staged, path)
        staged = None
    except (OSError, ValueError, UnicodeError):
        raise AuthError("Cannot publish CLI metadata.") from None
    finally:
        if staged is not None:
            try:
                staged.unlink(missing_ok=True)
            except OSError:
                raise AuthError("CLI metadata staging cleanup failed.") from None


def publish_mapping(path, document):
    try:
        text = json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    except (ValueError, TypeError):
        raise AuthError("Cannot serialize CLI metadata.") from None
    publish_text(path, text)
