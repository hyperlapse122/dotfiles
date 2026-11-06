"""Exercise managed T3 launchers, omp ACP, and native Codex/Claude initialization.

--install-desktop provisions an official desktop release on disposable CI only.
It does not test WinGet acquisition; the normal Windows apply uses WinGet.
"""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import base64
import secrets
import signal
import socket
import struct
import time

from asset_fixtures import copy_asset_templates
from smoke_personal_apps import executable, run, temporary_destination


REPO = Path(__file__).resolve().parents[1]


def provision_desktop(target, root, env):
    if not (env.get("GITHUB_ACTIONS") == "true" and env.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise RuntimeError("Desktop provisioning is restricted to disposable GitHub-hosted runners")
    if target == "darwin-arm64":
        run([executable("brew"), "install", "--cask", "t3-code"], env=env, cwd=root)
        return
    release = json.loads(run([executable("gh"), "api", "repos/pingdotgg/t3code/releases/latest"], env=env, cwd=root))
    if release.get("draft") or release.get("prerelease"):
        raise RuntimeError("Expected a stable T3 desktop release")
    arch = target.split("-", 1)[1]
    version = release["tag_name"].removeprefix("v")
    asset_name = f"T3-Code-{version}-{arch}.deb" if target.startswith("linux-") else f"T3-Code-{version}-{'x64' if arch == 'amd64' else 'arm64'}.exe"
    matches = [asset for asset in release["assets"] if asset["name"] == asset_name]
    if len(matches) != 1 or not matches[0].get("digest", "").startswith("sha256:"):
        raise RuntimeError(f"No uniquely checksummed T3 desktop asset: {asset_name}")
    asset = root / asset_name
    run([executable("gh"), "release", "download", release["tag_name"], "--repo", "pingdotgg/t3code", "--pattern", asset_name, "--dir", str(root)], env=env, cwd=root)
    with asset.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != matches[0]["digest"][7:]:
        raise RuntimeError("T3 desktop checksum mismatch")
    if target.startswith("windows-"):
        run([str(asset), "/S"], env=env, cwd=root)
    else:
        run([executable("sudo"), "apt-get", "update"], env=env, cwd=root)
        run([executable("sudo"), "apt-get", "install", "-y", str(asset)], env=env, cwd=root)


class T3Rpc:
    """Minimal stdlib client for T3's JSON Effect RPC WebSocket transport."""

    def __init__(self, port, token):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=60)
        self.stream = self.socket.makefile("rb")
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        self.socket.sendall((
            f"GET /ws?orchestrationProtocol=2 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n"
        ).encode())
        status = self.stream.readline()
        headers = {}
        while line := self.stream.readline().strip():
            name, value = line.decode().split(":", 1)
            headers[name.lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if b" 503 " in status:
            self.close()
            raise ConnectionRefusedError("T3 has bound its socket but is still starting")
        if b" 101 " not in status or headers.get("sec-websocket-accept") != expected:
            self.close()
            raise RuntimeError(f"T3 WebSocket upgrade failed: {status!r}")

    def close(self):
        self.stream.close()
        self.socket.close()

    def send(self, payload, opcode=1):
        mask = secrets.token_bytes(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", length)
        self.socket.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def read_exact(self, length):
        data = self.stream.read(length)
        if len(data) != length:
            raise RuntimeError("T3 closed its WebSocket before replying")
        return data

    def call(self, request_id, method, payload):
        self.send(json.dumps({"_tag": "Request", "id": request_id, "tag": method,
                              "payload": payload, "headers": []}).encode())
        fragments = bytearray()
        while True:
            first, second = self.read_exact(2)
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", self.read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.read_exact(8))[0]
            mask = self.read_exact(4) if second & 128 else None
            data = self.read_exact(length)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            opcode = first & 15
            if opcode == 8:
                raise RuntimeError(f"T3 closed its WebSocket: {data!r}")
            if opcode == 9:
                self.send(data, 10)
                continue
            if opcode == 10:
                continue
            fragments.extend(data)
            if not first & 128:
                continue
            decoded = json.loads(fragments)
            fragments.clear()
            for message in decoded if isinstance(decoded, list) else [decoded]:
                if message.get("_tag") == "Ping":
                    self.send(b'{"_tag":"Pong"}')
                if str(message.get("requestId")) == str(request_id):
                    if message.get("_tag") != "Exit" or message["exit"]["_tag"] != "Success":
                        raise RuntimeError(f"T3 RPC {method} failed: {message}")
                    return message["exit"]["value"]


class WindowsProcessJob:
    """Own descendants even if the command wrapper exits before teardown."""

    def __init__(self):
        import ctypes
        from ctypes import wintypes

        self.ctypes = ctypes
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateJobObjectW": ([ctypes.c_void_p, wintypes.LPCWSTR], wintypes.HANDLE),
            "OpenProcess": ([wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE),
            "AssignProcessToJobObject": ([wintypes.HANDLE, wintypes.HANDLE], wintypes.BOOL),
            "TerminateJobObject": ([wintypes.HANDLE, wintypes.UINT], wintypes.BOOL),
            "QueryInformationJobObject": ([wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                           wintypes.DWORD, ctypes.c_void_p], wintypes.BOOL),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "WaitForSingleObject": ([wintypes.HANDLE, wintypes.DWORD], wintypes.DWORD),
        }
        for name, (argtypes, restype) in signatures.items():
            function = getattr(self.kernel, name)
            function.argtypes, function.restype = argtypes, restype
        self.handle = self.check(self.kernel.CreateJobObjectW(None, None))

    def check(self, result):
        if not result:
            raise self.ctypes.WinError(self.ctypes.get_last_error())
        return result

    def assign(self, process):
        # AssignProcessToJobObject requires PROCESS_SET_QUOTA | PROCESS_TERMINATE.
        handle = self.check(self.kernel.OpenProcess(0x0100 | 0x0001, False, process.pid))
        try:
            self.check(self.kernel.AssignProcessToJobObject(self.handle, handle))
        finally:
            self.kernel.CloseHandle(handle)

    def terminate(self):
        handles = []
        try:
            capacity = 64
            while True:
                size = self.ctypes.sizeof(self.ctypes.c_size_t)
                members = self.ctypes.create_string_buffer(8 + capacity * size)
                # JobObjectBasicProcessIdList retains membership after the wrapper exits.
                if self.kernel.QueryInformationJobObject(
                        self.handle, 3, members, len(members), None):
                    break
                if self.ctypes.get_last_error() != 234:  # ERROR_MORE_DATA
                    self.check(False)
                capacity *= 2
            count = struct.unpack_from("I", members, 4)[0]
            for index in range(count):
                pid = self.ctypes.c_size_t.from_buffer(members, 8 + index * size).value
                handle = self.kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
                if handle:
                    handles.append(handle)
                elif self.ctypes.get_last_error() != 87:  # already exited
                    self.check(False)
            self.check(self.kernel.TerminateJobObject(self.handle, 1))
            deadline = time.monotonic() + 30
            # Termination and job membership updates precede release of Windows
            # resources. Wait for each process handle before deleting its cwd.
            for handle in handles:
                remaining = max(0, int((deadline - time.monotonic()) * 1000))
                result = self.kernel.WaitForSingleObject(handle, remaining)
                if result == 258:
                    raise TimeoutError("T3 server descendants did not exit within 30 seconds")
                if result != 0:
                    raise self.ctypes.WinError(self.ctypes.get_last_error())
        finally:
            for handle in handles:
                self.kernel.CloseHandle(handle)
            self.kernel.CloseHandle(self.handle)


@contextmanager
def server_process(args, **kwargs):
    job = WindowsProcessJob() if os.name == "nt" else None
    process = None
    try:
        process = subprocess.Popen(args, start_new_session=os.name != "nt", **kwargs)
        if job:
            try:
                job.assign(process)
            except Exception:
                process.kill()
                raise
        yield process
    finally:
        if job:
            job.terminate()
        elif process:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process:
            process.wait(timeout=30)


def prove_t3_provider(launcher, settings, env, outside, root, instance_id, expected_version):
    # Enable only the selected provider in this disposable server's settings.
    runtime = json.loads(settings.read_text(encoding="utf-8"))
    for name, provider in runtime["providerInstances"].items():
        provider["enabled"] = name == instance_id
        provider.setdefault("config", {})["enabled"] = name == instance_id
    settings.write_text(json.dumps(runtime), encoding="utf-8")
    safe_keys = {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP",
                 "LOCALAPPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432"}
    isolated = {key: value for key, value in env.items() if key.upper() in safe_keys}
    isolated.update({key: env[key] for key in (
        "HOME", "USERPROFILE", "APPDATA", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS",
        "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "T3CODE_HOME", "CODEX_HOME")})
    managed_bin = launcher.parent.resolve()
    isolated["PATH"] = os.pathsep.join(
        part for part in isolated.get("PATH", "").split(os.pathsep)
        if part and Path(part).resolve() != managed_bin)
    command_name = "claude" if instance_id == "claudeAgent" else "codex"
    if shutil.which(command_name, path=isolated["PATH"]):
        # An ambient harness must not mask an incorrect managed path.
        isolated["PATH"] = os.pathsep.join(
            part for part in isolated["PATH"].split(os.pathsep)
            if not any((Path(part) / name).is_file() for name in (command_name, command_name + ".exe", command_name + ".cmd")))
    token = secrets.token_hex(32)
    isolated["T3CODE_DEV_AUTH_TOKEN"] = token
    isolated["DO_NOT_TRACK"] = "1"
    isolated["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    # The native reusable development token is enabled only with a dev URL.
    args = [str(launcher), "--mode", "web", "--host", "127.0.0.1", "--port", str(port),
            "--no-browser", "--dev-url", f"http://127.0.0.1:{port}"]
    if os.name == "nt":
        shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
        args = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", *args]
    log_path = root / ("t3-" + instance_id + "-server.log")
    rpc = None
    with log_path.open("w+", encoding="utf-8", errors="backslashreplace") as log, server_process(
        args, env=isolated, cwd=outside, stdout=log, stderr=subprocess.STDOUT,
    ) as process:
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    raise RuntimeError("T3 server exited before accepting connections")
                try:
                    rpc = T3Rpc(port, token)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("T3 server did not start within 90 seconds")
                    time.sleep(0.2)
            config = rpc.call("1", "server.getConfig", {})
            managed = config["settings"]["providerInstances"][instance_id]
            expected = runtime["providerInstances"][instance_id]
            for key in ("binaryPath",):
                if managed["config"][key] != expected["config"][key]:
                    raise RuntimeError(f"T3 did not load the managed absolute {instance_id} {key}")
            refreshed = rpc.call("2", "server.refreshProviders", {"instanceId": instance_id, "fresh": True})
            provider = next(item for item in refreshed["providers"] if item["instanceId"] == instance_id)
            # A native initialization result identifies auth; --version fallback is unknown.
            if (not provider["enabled"] or not provider["installed"] or provider["driver"] != instance_id
                    or provider["version"] != expected_version
                    or provider["auth"]["status"] != "unauthenticated"):
                raise RuntimeError(f"T3 native {instance_id} initialization was not proven: {provider}")
            if instance_id == "claudeAgent":
                if (Path(env["HOME"]) / ".claude/.claude.json").exists():
                    raise RuntimeError("T3 split Claude's native default global state")
                global_config = json.loads((Path(env["HOME"]) / ".claude.json").read_text(encoding="utf-8"))
                if global_config.get("ownerScopeFixture") != "native-default":
                    raise RuntimeError("T3 changed unrelated default Claude global state")
                names = {item["name"].lstrip("/") for item in provider.get("slashCommands", [])}
                if "compound-engineering:ce-plan" not in names:
                    raise RuntimeError(f"T3 Claude initialization did not discover pinned CE: {names}")
            print(f"T3-driven {instance_id} {provider['version']} initialized (isolated, unauthenticated)", flush=True)
        except Exception as error:
            log.flush()
            log.seek(0)
            raise RuntimeError(f"{error}\nT3 server log:\n{log.read()}") from error
        finally:
            if rpc:
                rpc.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install-desktop", action="store_true")
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    real_home = Path.home()
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / name for name in ("user home", "source", "unrelated cwd"))
        for directory in (home, source, outside):
            directory.mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates", "private_dot_t3", "private_dot_claude", "dot_local"):
            shutil.copytree(REPO / "home" / relative, source / relative)
        shutil.copy2(REPO / "home/.chezmoiignore", source / ".chezmoiignore")
        config = root / "chezmoi.toml"
        config.write_text("", encoding="utf-8")
        env = {key: value for key, value in os.environ.items()
               if not key.upper().startswith(("CLAUDE", "ANTHROPIC_"))}
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "ZDOTDIR": str(home),
            "APPDATA": str(root / "appdata"),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "T3CODE_HOME": str(home / ".t3"),
            "CODEX_HOME": str(home / ".codex"),
        })
        # Keep native app-install discovery (LOCALAPPDATA/Applications) separate
        # from the isolated T3/omp runtime state; no registry action is copied.
        command = [chezmoi, "--source", str(source), "--destination", str(home), "--config", str(config),
                   "--cache", str(root / "cache"), "--persistent-state", str(root / "state.boltdb"), "--no-tty"]
        target = run(command + ["execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}"], env=env, cwd=outside)
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in {"windows-amd64", "windows-arm64", "linux-amd64", "linux-arm64", "darwin-arm64"}:
            raise RuntimeError(f"Unsupported T3 smoke target: {target}")
        if args.install_desktop:
            provision_desktop(target, root, os.environ.copy())
        binary_name = "omp.exe" if os.name == "nt" else "omp"
        existing_omp = real_home / ".local/bin" / binary_name
        if existing_omp.is_file():
            destination = home / ".local/bin" / binary_name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(existing_omp, destination)
        copy_asset_templates(source, ("personal-apps", "codex-package", "harness-plugins"))
        declaration = source / ".chezmoidata/personal-apps.json"
        data = json.loads(declaration.read_text(encoding="utf-8"))
        selected = ("codex", "claude") if existing_omp.is_file() else ("omp", "codex", "claude")
        data["personalApps"] = {name: data["personalApps"][name] for name in selected}
        declaration.write_text(json.dumps(data), encoding="utf-8")
        hooks = source / ".chezmoiscripts"
        hooks.mkdir()
        for name in ("run_after_26-claude-plugins.ps1.tmpl", "run_after_26-claude-plugins.sh.tmpl"):
            shutil.copy2(REPO / "home/.chezmoiscripts" / name, hooks / name)
        codex_home = home / ".codex"
        codex_home.mkdir()
        (codex_home / "config.toml").write_text(
            'check_for_update_on_startup = false\ncli_auth_credentials_store = "file"\n',
            encoding="utf-8")
        (home / ".claude.json").write_text(json.dumps({"ownerScopeFixture": "native-default"}), encoding="utf-8")
        settings = home / ".t3/userdata/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"idleCompaction": "onReturn", "providerInstances": {
            "smoke-unrelated": {"driver": "codex", "enabled": False, "displayName": "Unrelated smoke provider", "config": {}}
        }}), encoding="utf-8")
        run(command + ["apply", "--force"], env=env, cwd=outside)
        first = json.loads(settings.read_text(encoding="utf-8"))
        if first["providerInstances"]["smoke-unrelated"]["displayName"] != "Unrelated smoke provider" or first["idleCompaction"] != "onReturn":
            raise RuntimeError("Provider reconciliation changed unrelated settings")
        launcher = home / ".local/bin" / ("t3.ps1" if os.name == "nt" else "t3")
        if (home / ".t3/bin" / launcher.name).exists():
            raise RuntimeError("Smoke must not depend on an app-generated CLI shim")
        child = env.copy()
        child["PATH"] = str(launcher.parent) + os.pathsep + env.get("PATH", "")
        if os.name == "nt":
            shell = str(Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            version = run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "t3 --version; exit $LASTEXITCODE"], env=child, cwd=outside)
        else:
            version = run(["/bin/sh", "-c", "command -v t3; t3 --version"], env=child, cwd=outside)
        if "t3 v" not in version:
            raise RuntimeError(f"Unexpected bundled CLI version: {version}")
        provider = first["providerInstances"]["omp"]
        request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "dotfiles-smoke", "version": "1"}
        }}
        response = subprocess.run([provider["config"]["commandPath"], *provider["config"]["commandArgs"]],
                                  input=json.dumps(request) + "\n", env=child, cwd=outside,
                                  capture_output=True, text=True, encoding="utf-8", timeout=60)
        messages = [json.loads(line) for line in response.stdout.splitlines() if line.startswith("{")]
        initialized = next((message.get("result") for message in messages if message.get("id") == 1), None)
        if response.returncode or not initialized or initialized.get("agentInfo", {}).get("name") != "omp":
            raise RuntimeError(f"ACP initialization failed: {response.stdout}\n{response.stderr}")
        run(command + ["apply", "--force"], env=env, cwd=outside)
        if json.loads(settings.read_text(encoding="utf-8")) != first:
            raise RuntimeError("Repeated provider reconciliation did not converge")
        lock = json.loads((source / ".chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))
        expected_version = lock["personalAppLocks"]["codex"]["tag"].removeprefix("rust-v")
        prove_t3_provider(launcher, settings, env, outside, root, "codex", expected_version)
        prove_t3_provider(launcher, settings, env, outside, root, "claudeAgent",
                          lock["personalAppLocks"]["claude"]["tag"])
        print(f"Native {target}: {version}; managed omp ACP initialize succeeded; unrelated settings and reapply preserved")


if __name__ == "__main__":
    main()
