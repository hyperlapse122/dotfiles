"""Exercise real gh/Git/native-keyring interoperability on disposable runners only."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

from smoke_personal_apps import temporary_destination


REPO = Path(__file__).resolve().parents[1]
HOSTS = ("github.com", "gist.github.com")


def run(arguments, env, *, input=None, operation="Native authentication smoke"):
    result = subprocess.run(arguments, env=env, input=input, capture_output=True,
                            text=True, encoding="utf-8", timeout=120)
    if result.returncode:
        raise RuntimeError(operation + " failed")
    return result.stdout


def main():
    if not (os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise SystemExit("Native credential writes require a disposable GitHub-hosted runner")
    tools = {name: shutil.which(name) for name in ("chezmoi", "keyring", "git")}
    if not all(tools.values()):
        raise SystemExit("Native authentication smoke tools are missing")
    with temporary_destination() as scratch:
        root = Path(scratch)
        home = root / "home"
        source = root / "source"
        home.mkdir()
        source.mkdir()
        # This source has no authentication hooks and no owner secret data.
        for relative in (".chezmoidata", ".chezmoitemplates", ".chezmoiexternals"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        shutil.copy2(REPO / "home/dot_gitconfig.tmpl", source / "dot_gitconfig.tmpl")
        applications = source / ".chezmoidata/personal-apps.json"
        manifest = json.loads(applications.read_text(encoding="utf-8"))
        manifest["personalApps"] = {"gh": manifest["personalApps"]["gh"]}
        applications.write_text(json.dumps(manifest), encoding="utf-8")
        config = root / "chezmoi.toml"
        config.write_text("", encoding="utf-8")
        env = os.environ.copy()
        for name in list(env):
            if (name.startswith(("GH_", "GITHUB_", "GIT_CONFIG_", "GIT_TRACE", "KEYRING_PROPERTY_"))
                    or name in ("GIT_ASKPASS", "SSH_ASKPASS", "PYTHON_KEYRING_BACKEND", "PYTHONPATH",
                                "KEYCHAIN_PATH", "GIT_TRACE", "GIT_TRACE_CURL", "GIT_CURL_VERBOSE")):
                env.pop(name)
        env.update({
            "HOME": str(home), "USERPROFILE": str(home),
            "GH_CONFIG_DIR": str(root / "gh"),
            "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1",
            "XDG_CACHE_HOME": str(root / "cache"), "XDG_STATE_HOME": str(root / "state"),
        })
        # Preserve the session bus and OS Keychain/vault identity: the entire
        # hosted OS is disposable; HOME alone is not native-keyring isolation.
        command = [tools["chezmoi"], "--source", str(source), "--destination", str(home),
                   "--config", str(config), "--cache", str(root / "chezmoi-cache"),
                   "--persistent-state", str(root / "chezmoi-state"), "--no-tty"]
        run(command + ["apply", "--force", "--exclude=scripts"], env,
            operation="Install personal gh fixture")
        gh = home / ".local/bin" / ("gh.exe" if os.name == "nt" else "gh")
        if not gh.is_file():
            raise RuntimeError("Personal gh installation is missing")
        metadata = Path(env["GH_CONFIG_DIR"]) / "hosts.yml"
        metadata.parent.mkdir()
        login = "fixture-" + uuid.uuid4().hex
        token = "fixture-token-" + uuid.uuid4().hex
        metadata.write_text(json.dumps({"github.com": {"user": login, "git_protocol": "https",
                                                       "users": {login: {}}}}), encoding="utf-8")
        keyring = [tools["keyring"], "--keyring-path", str(REPO / "scripts"),
                   "--keyring-backend", "gh_native.Keyring"]
        records = []
        try:
            for host in HOSTS:
                for user in (login, ""):
                    identity = ["gh:" + host, user]
                    old = subprocess.run(keyring + ["get", *identity], env=env,
                                         capture_output=True, text=True, encoding="utf-8", timeout=120)
                    if old.returncode not in (0, 1):
                        raise RuntimeError("Native fixture read failed")
                    records.append((identity, old.stdout.removesuffix("\n") if old.returncode == 0 else None))
                    run(keyring + ["set", *identity], env, input=token, operation="Native fixture write")
            # An earlier store must neither return its stale credential nor
            # receive the managed PAT when Git broadcasts approve.
            store = root / "stale-credentials"
            store.write_text("".join("https://fixture:stale@" + host + "\n" for host in HOSTS), encoding="utf-8")
            prefix = root / "prefix.gitconfig"
            run([tools["git"], "config", "--file", str(prefix), "credential.helper",
                 'store --file="' + store.as_posix() + '"'], env)
            managed = home / ".gitconfig"
            managed.write_bytes(prefix.read_bytes() + managed.read_bytes())
            stale = store.read_bytes()
            for host in HOSTS:
                actual = run([str(gh), "auth", "token", "--hostname", host], env,
                             operation="Cross-library native token lookup").removesuffix("\n")
                if actual != token:
                    raise RuntimeError("Cross-library native token mismatch")
                request = "protocol=https\nhost=" + host + "\n\n"
                response = run([tools["git"], "-c", "core.askPass=", "credential", "fill"], env,
                               input=request, operation="Git native credential lookup")
                fields = dict(line.split("=", 1) for line in response.splitlines() if "=" in line)
                expected_user = login if host == "github.com" else "x-access-token"
                if fields.get("password") != token or fields.get("username") != expected_user:
                    raise RuntimeError("Git native credential mismatch")
                run([tools["git"], "credential", "approve"], env, input=response + "\n")
                if store.read_bytes() != stale:
                    raise RuntimeError("Managed credential reached the earlier file helper")
            print("Native gh and Git credential roundtrip passed for GitHub and Gist")
        finally:
            for identity, previous in reversed(records):
                arguments = keyring + (["delete", *identity] if previous is None else ["set", *identity])
                run(arguments, env, input=previous, operation="Native fixture cleanup")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Even a failed subprocess may hold a complete credential response.
        raise SystemExit("Native authentication smoke failed; credential output withheld") from None
