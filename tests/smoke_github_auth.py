"""Exercise real gh/Git/native-keyring interoperability on disposable runners only."""

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import traceback
import uuid
from unittest import mock

from smoke_personal_apps import temporary_destination


REPO = Path(__file__).resolve().parents[1]
HOSTS = ("github.com", "gist.github.com")


def run(arguments, env, *, input=None, operation="Native authentication smoke"):
    result = subprocess.run(arguments, env=env, input=input, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", timeout=120)
    if result.returncode:
        raise RuntimeError(operation + " failed")
    return result.stdout


@contextlib.contextmanager
def native_keychain(root, env):
    if sys.platform != "darwin":
        yield
        return
    security = "/usr/bin/security"
    default = shlex.split(run([security, "default-keychain", "-d", "user"], env))
    search = shlex.split(run([security, "list-keychains", "-d", "user"], env))
    if len(default) != 1:
        raise RuntimeError("Cannot identify the runner's default Keychain")
    target = str(root / "native-auth.keychain-db")
    with contextlib.ExitStack() as cleanup:
        run([security, "create-keychain", "-p", "ci-fixture-keychain", target], env)
        cleanup.callback(run, [security, "delete-keychain", target], env)
        cleanup.callback(run, [security, "list-keychains", "-d", "user", "-s", *search], env)
        cleanup.callback(run, [security, "default-keychain", "-d", "user", "-s", default[0]], env)
        run([security, "list-keychains", "-d", "user", "-s", target], env)
        run([security, "default-keychain", "-d", "user", "-s", target], env)
        run([security, "unlock-keychain", "-p", "ci-fixture-keychain", target], env)
        yield


def failure_summary(error):
    failures = [error]
    if error.__context__ is not None:
        failures.append(error.__context__)
    summaries = []
    for failure in failures:
        locations = " -> ".join(
            f"{Path(frame.filename).name}:{frame.lineno}"
            for frame in traceback.extract_tb(failure.__traceback__)
            if Path(frame.filename).name in ("smoke_github_auth.py", "github-auth.py")
        )
        summaries.append(type(failure).__name__ + (" at " + locations if locations else ""))
    return "Native authentication smoke failed: " + "; ".join(summaries) + "; credential output withheld"


def main():
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise SystemExit("Native credential writes require a disposable GitHub-hosted runner")
    tools = {name: shutil.which(name) for name in ("chezmoi", "keyring", "git", "gpg", "gpgconf")}
    if not all(tools.values()):
        raise SystemExit("Native authentication smoke tools are missing")
    with (temporary_destination() as scratch,
          tempfile.TemporaryDirectory(prefix="native-gpg-", dir=os.environ["RUNNER_TEMP"]) as gpg_scratch):
        root = Path(scratch)
        home = root / "home with 'quotes and caf\u00e9"
        repository = root / "repository"
        source = repository / "home"
        home.mkdir()
        source.mkdir(parents=True)
        shutil.copy2(REPO / ".chezmoiroot", repository)
        # Copy only public fixture inputs, not owner ciphertext or unrelated installers.
        for relative in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        (source / ".chezmoiexternals").mkdir()
        shutil.copy2(REPO / "home/.chezmoiexternals/personal-apps.toml.tmpl",
                     source / ".chezmoiexternals")
        for name in ("dot_gitconfig.tmpl", ".chezmoi.toml.tmpl"):
            shutil.copy2(REPO / "home" / name, source)
        (repository / "scripts").mkdir()
        shutil.copy2(REPO / "scripts/gh_native.py", repository / "scripts")
        applications = source / ".chezmoidata/personal-apps.json"
        manifest = json.loads(applications.read_text(encoding="utf-8"))
        manifest["personalApps"] = {"gh": manifest["personalApps"]["gh"]}
        applications.write_text(json.dumps(manifest), encoding="utf-8")
        config = root / "chezmoi.toml"
        config.write_text('[data]\ngpgProgram = ' + json.dumps(Path(tools["gpg"]).as_posix()) + '\n',
                          encoding="utf-8")
        # GPG's Windows agent needs a short data/socket path, unlike the Git path probe.
        gpg_profile = Path(gpg_scratch)
        gpg_home = (gpg_profile / "AppData/Roaming/gnupg"
                    if os.name == "nt" else gpg_profile / "gnupg")
        gpg_home.mkdir(parents=True, mode=0o700)
        env = os.environ.copy()
        for name in list(env):
            if (name.startswith(("GH_", "GITHUB_", "GIT_CONFIG_", "GIT_TRACE", "KEYRING_PROPERTY_"))
                    or name in ("GIT_ASKPASS", "SSH_ASKPASS", "PYTHON_KEYRING_BACKEND", "PYTHONPATH",
                                "KEYCHAIN_PATH", "GIT_CURL_VERBOSE")):
                env.pop(name)
        env.update({
            "HOME": str(home), "USERPROFILE": str(gpg_profile) if os.name == "nt" else str(home),
            "GNUPGHOME": str(gpg_home),
            "APPDATA": str(gpg_profile / "AppData/Roaming"),
            "LOCALAPPDATA": str(gpg_profile / "AppData/Local"),
            "GH_CONFIG_DIR": "~/gh fixture",
            "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1",
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
        })
        if sys.platform == "darwin":
            # Security resolves account Keychain preferences through the real HOME.
            # Git config, gh executable, and destination still use the complex fixture path.
            env["HOME"] = os.environ["HOME"]
        # HOME is not keyring isolation; preserve the disposable OS's session bus.
        command = [tools["chezmoi"], "--source", str(repository), "--destination", str(home),
                   "--config", str(config), "--cache", str(root / "chezmoi-cache"),
                   "--persistent-state", str(root / "chezmoi-state"), "--no-tty"]
        keyring = [tools["keyring"], "--keyring-path", str(repository / "scripts"),
                   "--keyring-backend", "gh_native.Keyring"]
        records = []
        keychain_scope = contextlib.ExitStack()
        try:
            keychain_scope.enter_context(native_keychain(root, env))
            run([tools["gpg"], "--no-options", "--batch", "--pinentry-mode", "loopback",
                 "--passphrase", "", "--quick-generate-key",
                 "Native Auth Fixture <fixture@example.invalid>", "rsa2048", "encr", "1d"], env,
                operation="Create disposable encryption key")
            listing = run([tools["gpg"], "--no-options", "--with-colons", "--list-keys"], env)
            recipient = next(line.split(":")[9] for line in listing.splitlines()
                             if line.startswith("fpr:"))
            data = source / ".chezmoidata/gpg.yaml"
            original = data.read_text(encoding="utf-8")
            data.write_text(original.replace("621512777E6933FEB4458FDC4945855D4F283F05", recipient),
                            encoding="utf-8")
            run(command + ["init"], env, operation="Initialize fixture encryption policy")
            # --exclude=scripts does not suppress config-level apply hooks.
            config.write_text(run(
                command + ["execute-template", '{{ unset (.chezmoi.stdin | fromToml) "hooks" | toToml }}',
                           "--with-stdin"],
                env, input=config.read_text(encoding="utf-8"),
                operation="Isolate fixture from personal apply hooks",
            ), encoding="utf-8")
            run(command + ["apply", "--force", "--exclude=scripts"], env,
                operation="Install personal gh fixture")
            gh = home / ".local/bin" / ("gh.exe" if os.name == "nt" else "gh")
            if not gh.is_file():
                raise RuntimeError("Personal gh installation is missing")
            spec = importlib.util.spec_from_file_location("native_github_auth", REPO / "scripts/github-auth.py")
            auth = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(auth)
            metadata = root / "~" / "gh fixture" / "hosts.yml"
            metadata.parent.mkdir(parents=True)
            login = "fixture-" + uuid.uuid4().hex
            other = "other-" + uuid.uuid4().hex
            unrelated_token = "unrelated-fixture-" + uuid.uuid4().hex
            unrelated_account = {"oauth_token": unrelated_token}
            unrelated_host = {"user": other, "oauth_token": unrelated_token}
            metadata.write_text(json.dumps({
                "github.com": {"user": other, "users": {other: unrelated_account}},
                "enterprise.invalid": unrelated_host,
            }), encoding="utf-8")
            for host in HOSTS:
                for user in (login, "", other):
                    identity = ["gh:" + host, user]
                    old = subprocess.run(keyring + ["get", *identity], env=env,
                                         capture_output=True, text=True, encoding="utf-8", timeout=120)
                    if old.returncode not in (0, 1):
                        raise RuntimeError("Native fixture read failed")
                    records.append((identity, old.stdout.removesuffix("\n") if old.returncode == 0 else None))
                run(keyring + ["set", "gh:" + host, other], env, input=unrelated_token)
            for user in (login, ""):
                run(keyring + ["set", "gh:gist.github.com", user], env, input="stale-gist-fixture")
            # Earlier generic helpers must not serve or receive either managed PAT.
            store = root / "stale-credentials"
            # credential-store's LF parser treats a Windows CR as part of the host.
            store.write_text(
                "".join("https://fixture:stale@" + host + "\n"
                        "http://fixture:control@" + host + "\n" for host in HOSTS)
                + "https://fixture:control@unrelated.invalid\n", encoding="utf-8", newline="\n")
            prefix = root / "prefix.gitconfig"
            run([tools["git"], "config", "--file", str(prefix), "credential.helper",
                 'store --file="' + store.as_posix() + '"'], env)
            managed = home / ".gitconfig"
            managed.write_bytes(prefix.read_bytes() + managed.read_bytes())
            stale = store.read_bytes()
            ciphertext = source / ".secrets/api-tokens.yaml.asc"
            ciphertext.parent.mkdir(mode=0o700)

            def write_token(token):
                encrypted = run(
                    [tools["gpg"], "--no-options", "--no-auto-check-trustdb", "--armor",
                     "--recipient", recipient, "--encrypt"], env,
                    input=json.dumps({"github": {"token": token}, "other": {"preserve": True}}),
                    operation="Encrypt fixture repository token",
                )
                ciphertext.write_text(encrypted, encoding="utf-8")

            def verify(token):
                document = json.loads(metadata.read_text(encoding="utf-8"))
                if (document["enterprise.invalid"] != unrelated_host
                        or document["github.com"]["users"].get(other) != unrelated_account
                        or token in metadata.read_text(encoding="utf-8")):
                    raise RuntimeError("Unrelated metadata changed or managed token reached a file")
                for host in HOSTS:
                    for flags in (["--user", login], []):
                        actual = run(
                            [str(gh), "auth", "token", "--secure-storage", "--no-refresh",
                             "--hostname", host, *flags], env,
                            operation="Cross-library per-user and active native lookup",
                        ).removesuffix("\n")
                        if actual != token:
                            raise RuntimeError("Cross-library native token mismatch")
                    ordinary = run([str(gh), "auth", "token", "--hostname", host], env).removesuffix("\n")
                    if ordinary != token:
                        raise RuntimeError("Ordinary gh lookup retained a stale credential")
                    preserved = run(keyring + ["get", "gh:" + host, other], env).removesuffix("\n")
                    if preserved != unrelated_token:
                        raise RuntimeError("Unrelated native account changed")
                    response = run(
                        [tools["git"], "-c", "core.askPass=", "credential", "fill"], env,
                        input="protocol=https\nhost=" + host + "\n\n",
                        operation="Git native credential lookup",
                    )
                    fields = dict(line.split("=", 1) for line in response.splitlines() if "=" in line)
                    expected_user = login if host in document else "x-access-token"
                    if fields.get("password") != token or fields.get("username") != expected_user:
                        raise RuntimeError("Git native credential mismatch")
                    run([tools["git"], "credential", "approve"], env, input=response + "\n")
                    if store.read_bytes() != stale:
                        raise RuntimeError("Managed credential reached the earlier file helper")
                if ("gist.github.com" in document
                        and document["gist.github.com"]["users"].get(other) != unrelated_account):
                    raise RuntimeError("Unrelated Gist account metadata changed")

            with (mock.patch.dict(os.environ, env, clear=True), contextlib.chdir(root),
                  mock.patch.object(auth, "github_login", return_value=login)):
                token = "initial-fixture-" + uuid.uuid4().hex
                write_token(token)
                auth.apply_auth(repository, config, home)
                verify(token)
                if "gist.github.com" in json.loads(metadata.read_text(encoding="utf-8")):
                    raise RuntimeError("Gist alias was registered as a new API host")
                auth.apply_auth(repository, config, home)
                verify(token)
                document = json.loads(metadata.read_text(encoding="utf-8"))
                document["gist.github.com"] = {
                    "user": login, "oauth_token": "stale-gist-fixture",
                    "users": {login: {"oauth_token": "stale-gist-fixture"}, other: unrelated_account},
                }
                metadata.write_text(json.dumps(document), encoding="utf-8")
                for user in (login, ""):
                    run(keyring + ["set", "gh:gist.github.com", user], env, input="stale-gist-fixture")
                token = "rotated-fixture-" + uuid.uuid4().hex
                write_token(token)
                auth.apply_auth(repository, config, home)
                verify(token)
                for host in HOSTS:
                    for user in (login, ""):
                        run(keyring + ["del", "gh:" + host, user], env)
                auth.apply_auth(repository, config, home)
                verify(token)
                for protocol, host in (("http", "github.com"), ("http", "gist.github.com"),
                                       ("https", "unrelated.invalid")):
                    response = run(
                        [tools["git"], "-c", "core.askPass=", "credential", "fill"], env,
                        input="protocol=" + protocol + "\nhost=" + host + "\n\n",
                    )
                    fields = dict(line.split("=", 1) for line in response.splitlines() if "=" in line)
                    if fields.get("password") != "control" or fields.get("username") != "fixture":
                        raise RuntimeError("Unrelated helper routing changed")
        finally:
            try:
                for identity, previous in reversed(records):
                    arguments = keyring + (["del", *identity] if previous is None else ["set", *identity])
                    run(arguments, env, input=previous, operation="Native fixture cleanup")
            finally:
                try:
                    subprocess.run([tools["gpgconf"], "--homedir", str(gpg_home), "--kill", "all"],
                                   env=env, capture_output=True, timeout=30)
                finally:
                    keychain_scope.close()
        print("Native production apply, repeat, rotation, repair, and GitHub/Gist routing passed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Exception messages and child output may contain complete credentials.
        raise SystemExit(failure_summary(error)) from None
