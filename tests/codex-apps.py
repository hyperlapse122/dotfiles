"""Exercise ordinary MCP discovery and calls through the packaged app server."""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time


def serve():
    for line in sys.stdin:
        frame = json.loads(line)
        if "id" not in frame:
            continue
        method = frame.get("method")
        if method == "initialize":
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "probe", "version": "1"},
            }
        elif method == "tools/list":
            result = {"tools": [{
                "name": "probe", "description": "Local MCP compatibility probe.",
                "inputSchema": {"type": "object", "properties": {}},
            }]}
        elif method == "tools/call":
            assert frame["params"]["name"] == "probe"
            result = {"content": [{"type": "text", "text": "probe-ok"}]}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": frame["id"], "result": result}), flush=True)


def check(wrapper):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        home, codex_home, work = (root / name for name in ("home", "codex", "work"))
        for path in (home, codex_home, work):
            path.mkdir()
        (codex_home / "config.toml").write_text(
            '[features]\napps = true\n\n[mcp_servers.local]\n'
            f'command = {json.dumps(sys.executable)}\n'
            f'args = {json.dumps([str(Path(__file__).resolve()), "--mcp"])}\n'
        )
        env = {"HOME": str(home), "CODEX_HOME": str(codex_home), "PATH": os.environ["PATH"]}
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen(
                [wrapper, "app-server"], cwd=work, env=env, text=True,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            )
            frames = queue.Queue()

            def read():
                for line in process.stdout:
                    frames.put(json.loads(line))
                frames.put(None)

            threading.Thread(target=read, daemon=True).start()
            serial = 0

            def request(method, params):
                nonlocal serial
                serial += 1
                process.stdin.write(json.dumps({
                    "id": serial, "method": method, "params": params,
                }) + "\n")
                process.stdin.flush()
                deadline = time.monotonic() + 30
                while True:
                    frame = frames.get(timeout=max(0.01, deadline - time.monotonic()))
                    assert frame is not None, "app server exited before replying"
                    if frame.get("id") == serial:
                        assert "error" not in frame, frame
                        return frame["result"]
                    assert time.monotonic() < deadline, "app server response timed out"

            try:
                request("initialize", {
                    "clientInfo": {"name": "connector-check", "version": "1"},
                    "capabilities": {"experimentalApi": True},
                })
                process.stdin.write('{"method":"initialized"}\n')
                process.stdin.flush()
                features = request("experimentalFeature/list", {})
                apps = next(feature for feature in features["data"] if feature["name"] == "apps")
                assert apps["enabled"] is False, "app-server leaves apps enabled"
                thread = request("thread/start", {"cwd": str(work), "ephemeral": True})
                thread_id = thread["thread"]["id"]
                status = request("mcpServerStatus/list", {"threadId": thread_id})
                servers = {server["name"]: server for server in status["data"]}
                assert set(servers) == {"local"}, servers
                assert "probe" in servers["local"]["tools"], servers
                response = request("mcpServer/tool/call", {
                    "threadId": thread_id, "server": "local", "tool": "probe", "arguments": {},
                })
                assert response["content"] == [{"type": "text", "text": "probe-ok"}], response
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    if sys.argv[1] == "--mcp":
        serve()
    else:
        check(sys.argv[1])
