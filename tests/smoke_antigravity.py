"""Apply locked Antigravity/CE and initialize its adapter through a fresh T3 server.

No model prompt, personal OAuth, real keyring operation, or personal apply is used.
Authenticated CE invocation is tracked in https://github.com/hyperlapse122/dotfiles/issues/52.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import time

from smoke_personal_apps import REPO, check_version, executable, run, temporary_destination
from smoke_t3_code import provision_desktop


def desktop_command(real_home, environment):
    if os.name == "nt":
        candidates = [Path(environment["LOCALAPPDATA"]) / "Programs/t3code/T3 Code (Beta).exe"]
        candidates.extend(Path(environment[key]) / "t3code/T3 Code (Beta).exe"
                          for key in ("PROGRAMW6432", "PROGRAMFILES", "PROGRAMFILES(X86)")
                          if environment.get(key))
        for app in candidates:
            if app.is_file():
                return [str(app), str(app.parent / "resources/server.asar/apps/server/dist/bin.mjs")]
    elif os.uname().sysname == "Darwin":
        bundles = [real_home / "Applications/T3 Code (Beta).app", Path("/Applications/T3 Code (Beta).app")]
        cask = Path("/opt/homebrew/Caskroom/t3-code")
        if cask.is_dir():
            bundles.extend(cask.glob("*/T3 Code (Beta).app"))
        for bundle in bundles:
            app = bundle / "Contents/MacOS/T3 Code (Beta)"
            if app.is_file():
                return [str(app), str(bundle / "Contents/Resources/app.asar/apps/server/dist/bin.mjs")]
    else:
        app = Path("/opt/T3 Code (Beta)/t3code")
        if app.is_file():
            return [str(app), str(app.parent / "resources/app.asar/apps/server/dist/bin.mjs")]
    raise RuntimeError("Install the T3 Code desktop application before running this smoke")


def rpc(port, token, method, payload):
    """Call the real T3 WebSocket API using its JSON RPC framing."""
    deadline = time.monotonic() + 60
    while True:
        stream = socket.create_connection(("127.0.0.1", port), timeout=90)
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            stream.sendall((
                f"GET /ws?orchestrationProtocol=2 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                f"Authorization: Bearer {token}\r\n\r\n"
            ).encode("ascii"))
            headers = b""
            while not headers.endswith(b"\r\n\r\n"):
                part = stream.recv(1)
                if not part:
                    raise RuntimeError("T3 closed the WebSocket upgrade")
                headers += part
            status = headers.split(b"\r\n", 1)[0]
            if b" 503 " in status and time.monotonic() < deadline:
                stream.close()
                time.sleep(1)
                continue
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            if b" 101 " not in status or expected.lower() not in headers.lower():
                raise RuntimeError("T3 rejected the disposable WebSocket session: " + headers.decode("ascii", errors="replace"))
            break
        except BaseException:
            stream.close()
            raise
    with stream:

        def send(message):
            data = json.dumps(message).encode("utf-8")
            mask = os.urandom(4)
            size = len(data)
            prefix = bytes((0x81, 0x80 | size)) if size < 126 else bytes((0x81, 0xFE)) + struct.pack("!H", size)
            stream.sendall(prefix + mask + bytes(value ^ mask[index % 4] for index, value in enumerate(data)))

        def read_exact(size):
            data = b""
            while len(data) < size:
                part = stream.recv(size - len(data))
                if not part:
                    raise RuntimeError("T3 closed the RPC session before replying")
                data += part
            return data

        send({"_tag": "Request", "id": 1, "tag": method, "payload": payload, "headers": []})
        fragments = b""
        while True:
            first, second = read_exact(2)
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", read_exact(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", read_exact(8))[0]
            mask = read_exact(4) if second & 128 else None
            data = read_exact(size)
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            opcode = first & 15
            if opcode == 8:
                raise RuntimeError("T3 closed the WebSocket before the provider reply")
            if opcode not in (0, 1):
                continue
            fragments += data
            if not first & 0x80:
                continue
            message = json.loads(fragments)
            fragments = b""
            if message.get("_tag") == "Ping":
                send({"_tag": "Pong"})
            elif message.get("_tag") == "Exit" and message.get("requestId") == 1:
                if message["exit"]["_tag"] != "Success":
                    raise RuntimeError("T3 provider RPC failed: " + json.dumps(message["exit"]))
                return message["exit"]["value"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    parser.add_argument("--install-desktop", action="store_true")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    real_home = Path.home()
    real_environment = os.environ.copy()
    app_locks = json.loads((REPO / "home/.chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))["personalAppLocks"]
    ce_pin = json.loads((REPO / "home/.chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))["harnessPluginLocks"]["compound-engineering"]
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / name for name in ("user home", "source", "outside"))
        for directory in (home, source, outside):
            directory.mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates", "dot_local", "private_dot_gemini", "private_dot_t3"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        for relative in (".chezmoiignore", ".chezmoiexternals/personal-apps.toml.tmpl",
                         ".chezmoiexternals/harness-plugins.toml.tmpl",
                         ".chezmoiscripts/run_after_20-antigravity-plugins.sh.tmpl",
                         ".chezmoiscripts/run_after_20-antigravity-plugins.ps1.tmpl"):
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / "home" / relative, destination)
        declaration = source / ".chezmoidata/personal-apps.json"
        apps = json.loads(declaration.read_text(encoding="utf-8"))
        apps["personalApps"] = {name: apps["personalApps"][name] for name in ("antigravity", "antigravity-acp")}
        declaration.write_text(json.dumps(apps), encoding="utf-8")
        config = root / "chezmoi.toml"
        config_text = ""
        if os.name == "nt":
            shell = Path(real_environment["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config_text = ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell))
                           + '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config.write_text(config_text, encoding="utf-8")
        env = real_environment.copy()
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "APPDATA": str(root / "appdata"),
            "LOCALAPPDATA": str(root / "local"), "ZDOTDIR": str(home),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "T3CODE_HOME": str(home / ".t3"),
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true", "NO_COLOR": "1",
        })
        for key in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "AGY_ADC_AUTH"):
            env.pop(key, None)
        # Missing API-key configuration fails before native account/keyring sign-in.
        cli_settings = home / ".gemini/antigravity-cli/settings.json"
        cli_settings.parent.mkdir(parents=True)
        cli_settings.write_text(json.dumps({"modelProvider": "gemini", "unrelatedSmokeSetting": "retain"}), encoding="utf-8")
        t3_settings = home / ".t3/userdata/settings.json"
        t3_settings.parent.mkdir(parents=True)
        disabled = {name: {"driver": name, "enabled": False, "config": {}}
                    for name in ("codex", "claudeAgent", "cursor", "grok", "opencode", "pi")}
        disabled["smoke-unrelated"] = {"driver": "codex", "enabled": False, "config": {"keep": "value"}}
        t3_settings.write_text(json.dumps({"idleCompaction": "onReturn", "providerInstances": disabled}), encoding="utf-8")
        command = [chezmoi, "--config", str(config), "--source", str(source), "--destination", str(home),
                   "--cache", str(root / "cache"), "--persistent-state", str(root / "state.boltdb"), "--no-tty"]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in app_locks["antigravity"]["targets"]:
            raise RuntimeError(f"No locked Antigravity target: {target}")
        if args.install_desktop:
            provision_desktop(target, root, real_environment)
        t3 = desktop_command(real_home, real_environment)
        chez("apply", "--force")
        binary_suffix = ".exe" if os.name == "nt" else ""
        cli = home / ".local/share/dotfiles/antigravity/bin" / ("agy" + binary_suffix)
        launcher_suffix = ".cmd" if os.name == "nt" else ""
        launcher = home / ".local/bin" / ("antigravity-acp" + launcher_suffix)
        agy_launcher = home / ".local/bin" / ("agy" + launcher_suffix)

        def launch(path, *arguments):
            invocation = [str(path), *arguments]
            if os.name == "nt":
                invocation = [real_environment["COMSPEC"], "/d", "/c", *invocation]
            return run(invocation, env=env, cwd=outside)

        for name, path in (("antigravity", agy_launcher), ("antigravity-acp", launcher)):
            version = launch(path, "--version")
            check_version(version, app_locks[name]["tag"])
            print(f"Native {target}: {name} {version}")
        plugins = json.loads(run([str(cli), "plugin", "list", "--json"], env=env, cwd=outside))
        managed = [plugin for plugin in plugins if plugin["name"] == "compound-engineering"]
        if len(managed) != 1 or not managed[0]["enabled"] or "ce-pov" not in managed[0]["skills"]:
            raise RuntimeError("Pinned CE is not enabled and natively discoverable")
        check_version(managed[0]["version"], ce_pin["tag"].removeprefix("compound-engineering-"))
        run([str(cli), "plugin", "validate", managed[0]["path"]], env=env, cwd=outside)
        if not (home / ".gemini/GEMINI.md").is_file():
            raise RuntimeError("Native shared-instruction adapter was not created")
        first = json.loads(t3_settings.read_text(encoding="utf-8"))
        provider = first["providerInstances"]["antigravity"]
        adapter = home / ".local/share/dotfiles/antigravity-acp/bin" / ("antigravity-acp" + binary_suffix)
        if provider["config"]["commandPath"] != adapter.as_posix() or provider["config"]["commandArgs"] != []:
            raise RuntimeError("T3 does not use the absolute native adapter executable")
        environment = {item["name"]: item["value"] for item in provider["environment"]}
        if environment.get("AGY_BIN") != cli.as_posix() or environment.get("AGY_SKIP_DOWNLOAD") != "1":
            raise RuntimeError("T3 does not select the pinned CLI without adapter auto-download")
        run([str(cli), "plugin", "disable", "compound-engineering"], env=env, cwd=outside)
        drifted = json.loads(json.dumps(first))
        drifted["providerInstances"]["antigravity"]["enabled"] = False
        drifted["providerInstances"]["antigravity"]["config"]["commandPath"] = "wrong"
        t3_settings.write_text(json.dumps(drifted), encoding="utf-8")
        for _ in range(2):
            chez("apply", "--force")
        if json.loads(t3_settings.read_text(encoding="utf-8")) != first:
            raise RuntimeError("Repeated provider reconciliation did not converge")
        if json.loads(cli_settings.read_text(encoding="utf-8"))["unrelatedSmokeSetting"] != "retain":
            raise RuntimeError("Apply changed unrelated Antigravity settings")
        for name, path in (("antigravity", agy_launcher), ("antigravity-acp", launcher)):
            check_version(launch(path, "--version"), app_locks[name]["tag"])
        plugins = json.loads(run([str(cli), "plugin", "list", "--json"], env=env, cwd=outside))
        if not next(plugin for plugin in plugins if plugin["name"] == "compound-engineering")["enabled"]:
            raise RuntimeError("Reapply did not restore native CE enablement")
        env["PATH"] = os.pathsep.join(part for part in env.get("PATH", "").split(os.pathsep)
                                    if part and ".local" + os.sep + "bin" not in os.path.normcase(part)
                                    and ".local/bin" not in part.replace("\\", "/").lower())
        env.update({"ELECTRON_RUN_AS_NODE": "1", "T3CODE_DESKTOP_CLI_LAUNCHER": "1"})
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        token = run(t3 + ["auth", "session", "issue", "--base-dir", str(home / ".t3"),
                         "--scope", "providers:manage", "--scope", "orchestration:read",
                         "--ttl", "5m", "--token-only"], env=env, cwd=outside)
        with (root / "t3.log").open("w", encoding="utf-8") as log:
            process = subprocess.Popen(t3 + ["serve", "--mode", "desktop", "--host", "127.0.0.1",
                                             "--port", str(port), "--base-dir", str(home / ".t3"), "--no-browser"],
                                       env=env, cwd=outside, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=os.name != "nt")
            try:
                deadline = time.monotonic() + 60
                while True:
                    if process.poll() is not None:
                        raise RuntimeError("Fresh T3 server exited: " + (root / "t3.log").read_text(encoding="utf-8"))
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=1):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Fresh T3 server did not become ready")
                        time.sleep(0.1)
                refreshed = rpc(port, token, "server.refreshProviders", {
                    "instanceId": "antigravity", "cwd": str(outside), "fresh": True, "refreshModels": True,
                })
                snapshots = refreshed.get("providers", [])
                snapshot = next((item for item in snapshots if item["instanceId"] == "antigravity"), None)
                if snapshot is None or not snapshot.get("installed") or snapshot.get("status") == "error":
                    raise RuntimeError("Fresh T3 did not initialize managed ACP: " + json.dumps(refreshed))
                if not snapshot.get("nativeSessions", {}).get("canList"):
                    raise RuntimeError("T3 did not receive the adapter's ACP session capabilities: " + json.dumps(snapshot))
                print(f"Fresh T3 {target}: managed Antigravity ACP initialized with .local/bin absent from PATH")
            except Exception:
                print((root / "t3.log").read_text(encoding="utf-8", errors="replace"))
                raise
            finally:
                if os.name == "nt":
                    subprocess.run([real_environment["SYSTEMROOT"] + "/System32/taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                                   capture_output=True, timeout=30)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=30)
        print("Verified: pinned versions, native CE discovery/validation, enabled-state repair, unrelated settings, and real T3 ACP initialization")
        print("Authenticated CE skill invocation remains deferred to issue #52")


if __name__ == "__main__":
    main()
