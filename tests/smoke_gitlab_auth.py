"""Prove real glab/Git/native-keyring interoperability on disposable runners."""

import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid
from unittest import mock

from smoke_github_auth import native_keychain, run
from smoke_personal_apps import temporary_destination


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))


def main():
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise SystemExit("Native credential writes require a disposable GitHub-hosted runner")
    tools = {name: shutil.which(name) for name in ("chezmoi", "keyring", "git", "gpg", "gpgconf")}
    if not all(tools.values()):
        raise SystemExit("Native GitLab smoke prerequisites are missing")
    with (temporary_destination() as scratch,
          tempfile.TemporaryDirectory(prefix="glab-gpg-", dir=os.environ["RUNNER_TEMP"]) as gpg_scratch):
        root = Path(scratch)
        home = root / "home with 'quotes and caf\u00e9"
        repository = root / "repository"
        source = repository / "home"
        home.mkdir()
        source.mkdir(parents=True)
        shutil.copy2(REPO / ".chezmoiroot", repository)
        for relative in (".chezmoidata", ".chezmoitemplates"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        (source / ".chezmoiexternals").mkdir()
        shutil.copy2(REPO / "home/.chezmoiexternals/personal-apps.toml.tmpl", source / ".chezmoiexternals")
        for name in ("dot_gitconfig.tmpl", ".chezmoi.toml.tmpl"):
            shutil.copy2(REPO / "home" / name, source)
        (repository / "scripts").mkdir()
        shutil.copy2(REPO / "scripts/cli_native.py", repository / "scripts")
        apps = source / ".chezmoidata/personal-apps.json"
        manifest = json.loads(apps.read_text(encoding="utf-8"))
        manifest["personalApps"] = {"glab": manifest["personalApps"]["glab"]}
        apps.write_text(json.dumps(manifest), encoding="utf-8")
        config = root / "chezmoi.toml"
        config.write_text('[data]\ngpgProgram = ' + json.dumps(Path(tools["gpg"]).as_posix()) + '\n',
                          encoding="utf-8")
        profile = Path(gpg_scratch)
        gpg_home = profile / ("AppData/Roaming/gnupg" if os.name == "nt" else "gnupg")
        gpg_home.mkdir(parents=True, mode=0o700)
        env = os.environ.copy()
        for name in list(env):
            if (name.startswith(("GH_", "GITHUB_", "GITLAB_", "GLAB_", "GIT_CONFIG_", "GIT_TRACE", "KEYRING_PROPERTY_"))
                    or name in ("GIT_ASKPASS", "SSH_ASKPASS", "PYTHON_KEYRING_BACKEND", "PYTHONPATH",
                                "KEYCHAIN_PATH", "GIT_CURL_VERBOSE", "GL_HOST", "OAUTH_TOKEN")):
                env.pop(name)
        env.update({
            "HOME": str(home), "USERPROFILE": str(profile) if os.name == "nt" else str(home),
            "GNUPGHOME": str(gpg_home), "APPDATA": str(profile / "AppData/Roaming"),
            "LOCALAPPDATA": str(profile / "AppData/Local"), "GLAB_CONFIG_DIR": str(root / "glab"),
            "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GLAB_NO_PROMPT": "true", "GLAB_CHECK_UPDATE": "false",
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
        })
        if sys.platform == "darwin":
            env["HOME"] = os.environ["HOME"]
        command = [tools["chezmoi"], "--source", str(repository), "--destination", str(home),
                   "--config", str(config), "--cache", str(root / "chezmoi-cache"),
                   "--persistent-state", str(root / "chezmoi-state"), "--no-tty"]
        keyring = [tools["keyring"], "--keyring-path", str(repository / "scripts"),
                   "--keyring-backend", "cli_native.Keyring"]
        host = "fixture-" + uuid.uuid4().hex + ".invalid"
        user = "fixture-owner"
        service = "glab:" + host + ":token"
        registered = False
        with native_keychain(root, env):
            try:
                run([tools["gpg"], "--no-options", "--batch", "--pinentry-mode", "loopback",
                     "--passphrase", "", "--quick-generate-key", "GitLab Fixture <fixture@example.invalid>",
                     "rsa2048", "encr", "1d"], env, operation="Create disposable GPG key")
                listing = run([tools["gpg"], "--no-options", "--with-colons", "--list-keys"], env)
                recipient = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
                data = source / ".chezmoidata/gpg.yaml"
                data.write_text(data.read_text(encoding="utf-8").replace(
                    "621512777E6933FEB4458FDC4945855D4F283F05", recipient), encoding="utf-8")
                run(command + ["init"], env, operation="Initialize fixture GPG policy")
                config.write_text(run(command + ["execute-template", "--with-stdin",
                                                 '{{ unset (.chezmoi.stdin | fromToml) "hooks" | toToml }}'],
                                      env, input=config.read_text(encoding="utf-8")), encoding="utf-8")
                run(command + ["apply", "--force", "--exclude=scripts"], env, operation="Install personal glab fixture")
                glab = home / ".local/bin" / ("glab.exe" if os.name == "nt" else "glab")
                run([str(glab), "--version"], env, operation="Run pinned personal glab")
                spec = importlib.util.spec_from_file_location("smoke_gitlab_auth", REPO / "scripts/gitlab-auth.py")
                auth = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(auth)
                metadata = root / "glab/config.yml"
                metadata.parent.mkdir(exist_ok=True)
                unrelated = {"user": "other", "token": "unrelated-fixture"}
                metadata.write_text(json.dumps({"is_oauth2": "true", "host": "other.invalid",
                                               "hosts": {"other.invalid": unrelated,
                                                         host: {"token": "stale", "is_oauth2": "true",
                                                                "oauth2_refresh_token": "stale-refresh"}}}), encoding="utf-8")
                run([tools["git"], "init", str(repository)], env)
                local = repository / ".git/glab-cli/config.yml"
                local.parent.mkdir()
                local.write_text('is_oauth2: "true"\n', encoding="utf-8")
                ciphertext = source / ".secrets/api-tokens.yaml.asc"
                ciphertext.parent.mkdir(mode=0o700)

                def write_token(token):
                    ciphertext.write_text(run(
                        [tools["gpg"], "--no-options", "--no-auto-check-trustdb", "--armor",
                         "--recipient", recipient, "--encrypt"], env,
                        input=json.dumps({"gitlab": {"host": host, "registry": "registry.example.invalid",
                                                      "user": user, "token": token}}),
                        operation="Encrypt synthetic GitLab credentials"), encoding="utf-8")

                def verify(token):
                    document = json.loads(metadata.read_text(encoding="utf-8"))
                    if (document["hosts"]["other.invalid"] != unrelated
                            or document["host"] != "other.invalid"
                            or token in metadata.read_text(encoding="utf-8")):
                        raise RuntimeError("GitLab metadata preservation failed")
                    result = run([tools["git"], "-C", str(repository), "-c", "core.askPass=", "credential", "fill"],
                                 env, input="protocol=https\nhost=" + host + "\n\n",
                                 operation="Git-to-glab native credential lookup")
                    fields = dict(line.split("=", 1) for line in result.splitlines() if "=" in line)
                    if fields.get("username") != user or fields.get("password") != token:
                        raise RuntimeError("GitLab native credential mismatch")

                with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(auth, "gitlab_user", return_value=user):
                    for token in ("initial-" + uuid.uuid4().hex, "rotated-" + uuid.uuid4().hex):
                        write_token(token)
                        registered = True
                        auth.apply_auth(repository, config, home)
                        verify(token)
                        auth.apply_auth(repository, config, home)
                        verify(token)
                    run(keyring + ["del", service, ""], env, operation="Remove synthetic keyring entry")
                    registered = False
                    registered = True
                    auth.apply_auth(repository, config, home)
                    verify(token)
            finally:
                try:
                    if registered:
                        run(keyring + ["del", service, ""], env, operation="Clean up synthetic keyring entry")
                finally:
                    subprocess.run([tools["gpgconf"], "--homedir", str(gpg_home), "--kill", "all"],
                                   env=env, capture_output=True, timeout=30)
    print("Native GitLab apply, repeat, rotation, repair, and Git HTTPS routing passed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("Native GitLab smoke failed (" + type(error).__name__ + "); private output withheld") from None
