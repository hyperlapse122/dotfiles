"""Real pinned ACP and rendered T3 launch contracts; no live app proof implied."""

import json
import http.server
import os
from pathlib import Path
import queue
import ssl
import subprocess
import sys
import tempfile
import threading
import time


class Acp:
    def __init__(self, config, home, work, extra_env):
        self.events = []
        self.replies = {}
        self.frames = queue.Queue()
        self.serial = 0
        self.stderr = tempfile.TemporaryFile(mode="w+")
        env = {"HOME": str(home), "PATH": os.environ["PATH"],
               "SYNTHETIC_API_KEY": "sk-fake-synthetic", "OPENROUTER_API_KEY": "sk-fake-openrouter",
               **extra_env}
        self.process = subprocess.Popen([config["commandPath"], *config["commandArgs"]],
                                        cwd=work, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr, text=True)
        def read():
            for line in self.process.stdout:
                self.frames.put(json.loads(line))
            self.frames.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def send(self, method, params, request=True):
        frame = {"jsonrpc": "2.0", "method": method, "params": params}
        if request:
            self.serial += 1
            frame["id"] = self.serial
        self.process.stdin.write(json.dumps(frame) + "\n")
        self.process.stdin.flush()
        return frame.get("id")

    def receive(self, number, timeout=30, allow_error=False):
        deadline = time.monotonic() + timeout
        while number not in self.replies:
            frame = self.frames.get(timeout=max(0.01, deadline - time.monotonic()))
            assert frame is not None, "ACP exited before replying"
            if "method" in frame:
                if "id" in frame:
                    assert frame["method"] == "session/request_permission", frame
                    option = next(o for o in frame["params"]["options"] if o["kind"] == "allow_once")
                    self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": frame["id"],
                                                        "result": {"outcome": {"outcome": "selected",
                                                                               "optionId": option["optionId"]}}}) + "\n")
                    self.process.stdin.flush()
                else:
                    self.events.append(frame)
            else:
                self.replies[frame["id"]] = frame
        frame = self.replies.pop(number)
        if allow_error:
            return frame
        assert "error" not in frame, frame
        return frame["result"]

    def call(self, method, **params):
        return self.receive(self.send(method, params))

    def initialize(self):
        response = self.call("initialize", protocolVersion=1,
                             clientCapabilities={"elicitation": {"form": {}}})
        assert response["agentInfo"]["name"] == "omp"
        assert response["agentCapabilities"]["loadSession"] is True
        return response

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        self.process.stdin.close()
        self.process.stdout.close()
        self.stderr.close()


def option(state, name):
    return next(row for row in state["configOptions"] if row["id"] == name)


def values(state, name):
    return {row["value"] for row in option(state, name)["options"]}


def prepare(entry, home):
    agent = home / ".omp/agent"
    agent.mkdir(parents=True)
    for name, path in entry["documents"].items():
        (agent / name).write_bytes(Path(path).read_bytes())
    # Protected production helper commands remain the consumer; only fake
    # credentials enter this process, and the sandbox has no user auth files.
    providers = json.loads((agent / "models.yml").read_text())["providers"]
    assert set(providers) == {"synthetic", "openrouter"}, "only Synthetic and OpenRouter may be declared"
    skill = agent / "skills/u5-proof"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: u5-proof\ndescription: ACP_SKILL_PROOF\n---\nACP skill fixture.\n")
    work = home / "project"
    work.mkdir()
    (work / "AGENTS.md").write_text("ACP_REPOSITORY_PROOF\n")
    return work


SMOL_MODEL = "hf:deepseek-ai/DeepSeek-V4.1-Flash"


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def json_response(self, data, status=200):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_CONNECT(self):
        assert self.path in ("api.synthetic.new:443", "openrouter.ai:443"), self.path
        self.send_response(200)
        self.end_headers()
        try:
            self.connection = self.server.tls.wrap_socket(self.connection, server_side=True)
        except (ConnectionResetError, ssl.SSLEOFError):
            # OMP cancels background discovery connections on process exit.
            return
        self.rfile = self.connection.makefile("rb")
        self.wfile = self.connection.makefile("wb")
        self.close_connection = False
        self.handle_one_request()

    def do_GET(self):
        self.send_error(404)

    def do_POST(self):
        try:
            self.respond()
        except (AssertionError, StopIteration) as error:
            self.server.errors.append(str(error))
            self.json_response({"error": {"message": str(error)}}, 400)

    def respond(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/mcp":
            self.server.mcp_frames.append(body)
            if "id" not in body:
                self.json_response({}, 202)
                return
            method = body["method"]
            if method == "initialize":
                result = {"protocolVersion": body["params"]["protocolVersion"], "capabilities": {"tools": {}},
                          "serverInfo": {"name": "u5-fixture", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": [{"name": "proof", "description": "Return a protocol fixture nonce",
                                     "inputSchema": {"type": "object", "properties": {}}}]}
            elif method == "tools/call":
                assert body["params"]["name"] == "proof", body
                self.server.mcp_calls.append(body)
                result = {"content": [{"type": "text", "text": self.server.nonce}]}
            else:
                self.json_response({"jsonrpc": "2.0", "id": body["id"],
                                    "error": {"code": -32601, "message": "unknown method"}})
                return
            self.json_response({"jsonrpc": "2.0", "id": body["id"], "result": result})
            return
        if body.get("model") == SMOL_MODEL:
            # OMP's smol role condenses skill descriptions into the routing
            # hints the main prompt lists; keep the description as the hint.
            self.server.side_requests.append(body)
            prompt = str(body["messages"][-1]["content"])
            self.stream({"content": prompt.rpartition("Description: ")[2].strip()}, "stop")
            return
        self.server.requests.append(body)
        assert self.path == "/openai/v1/chat/completions", self.path
        messages = str(body["messages"])
        last_user = str(next(m for m in reversed(body["messages"]) if m["role"] == "user"))
        if "ACP_CANCEL" in last_user:
            self.server.cancel_started.set()
            self.server.cancel_release.wait(20)
            return
        assert "ACP_REPOSITORY_PROOF" in messages, "ACP omitted repository instructions"
        assert "ACP_SKILL_PROOF" in messages, "ACP omitted native skill discovery"
        results = str([m for m in body["messages"] if m["role"] == "tool"])
        if "ACP_INTERACTION" in messages:
            if not any(m["role"] == "tool" for m in body["messages"]):
                delta, reason = self.tool("todo", {"op": "init", "list": [
                    {"phase": "Decision", "items": ["Await fixture choice"]}]}), "tool_calls"
            elif "incomplete todo item(s)" in messages:
                delta, reason = {"content": "ACP_REMINDER_CONTINUATION"}, "stop"
            else:
                assert "Await fixture choice" in results and any(
                    status in results for status in ("[pending]", "[in_progress]")), results
                delta, reason = {"content": INTERACTION_ANSWER}, "stop"
        elif "ACP_RESUME" in last_user:
            assert self.server.nonce in results, "resume lost prior MCP result"
            delta, reason = {"content": "ACP_RESUMED"}, "stop"
        elif not any(m["role"] == "tool" for m in body["messages"]):
            delta, reason = self.tool("write", {"i": "Writing ACP proof", "path": "acp-proof.txt",
                                                "content": "ACP_NATIVE_TOOL_RESULT\n"}), "tool_calls"
        elif self.server.nonce not in results:
            # OMP natively mounts MCP tools under xd:// rather than sending
            # each full schema as a top-level provider tool.
            assert "mcp__fixture_proof" in messages, "MCP mount absent from provider context"
            delta, reason = self.tool("write", {"i": "Calling injected MCP tool", "path": "xd://mcp__fixture_proof",
                                                "content": "{}"}), "tool_calls"
        else:
            delta, reason = {"content": "ACP_COMPLETED " + self.server.nonce}, "stop"
        self.stream(delta, reason)

    def stream(self, delta, reason):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for payload in ({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                        {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]}):
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    @staticmethod
    def tool(name, arguments):
        return {"tool_calls": [{"index": 0, "id": "call_" + name, "type": "function",
                                "function": {"name": name, "arguments": json.dumps(arguments)}}]}


def endpoint(home):
    cert, key = home / "cert.pem", home / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-keyout", str(key), "-out", str(cert), "-subj", "/CN=ACP fixture",
                    "-addext", "subjectAltName=DNS:api.synthetic.new"], check=True, capture_output=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    server.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.tls.load_cert_chain(cert, key)
    server.requests, server.side_requests, server.mcp_calls, server.mcp_frames, server.errors = [], [], [], [], []
    server.nonce = "MCP_RESULT_" + os.urandom(8).hex()
    server.cancel_started, server.cancel_release = threading.Event(), threading.Event()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    proxy = f"http://127.0.0.1:{server.server_port}"
    env = {"NODE_EXTRA_CA_CERTS": str(cert), "PI_PROXY_SYNTHETIC": proxy, "PI_PROXY_OPENROUTER": proxy}
    mcp = [{"type": "http", "name": "fixture", "url": proxy + "/mcp", "headers": []}]
    return server, env, mcp


def exchange(config, home, work):
    server, env, mcp = endpoint(home)
    client = Acp(config, home, work, env)
    try:
        client.initialize()
        state = client.call("session/new", cwd=str(work), mcpServers=mcp)
        session = state["sessionId"]
        assert option(state, "model")["currentValue"] == STARTUP_MODEL, state
        assert option(state, "thinking")["currentValue"] == "high", option(state, "thinking")
        state = client.call("session/set_config_option", sessionId=session, configId="model",
                            value="synthetic/hf:zai-org/GLM-5.3")
        state = client.call("session/set_config_option", sessionId=session, configId="thinking", value="max")
        reply = client.call("session/prompt", sessionId=session,
                            prompt=[{"type": "text", "text": "ACP_EXCHANGE: write a file and call the MCP fixture."}])
        assert reply["stopReason"] == "end_turn", (reply, server.errors)
        assert not server.errors, server.errors
        assert (work / "acp-proof.txt").read_text() == "ACP_NATIVE_TOOL_RESULT\n"
        assert len(server.mcp_calls) == 1, server.mcp_calls
        assert len(server.requests) == 3, len(server.requests)
        assert all(body["model"] == "hf:zai-org/GLM-5.3" and body.get("reasoning_effort") == "max"
                   for body in server.requests), "ACP effective default differs from actual requests"
        updates = [e["params"]["update"] for e in client.events if e["method"] == "session/update"]
        assert any(u["sessionUpdate"] == "tool_call_update" and u.get("status") == "completed" for u in updates)
        assert any(server.nonce in str(u) and u["sessionUpdate"] == "agent_message_chunk" for u in updates)
        pending = client.send("session/prompt", {"sessionId": session,
                              "prompt": [{"type": "text", "text": "ACP_CANCEL"}]})
        assert server.cancel_started.wait(10), "cancel test never reached the provider request"
        client.send("session/cancel", {"sessionId": session}, request=False)
        assert client.receive(pending, timeout=10)["stopReason"] == "cancelled"
        server.cancel_release.set()
        client.close()
        client = Acp(config, home, work, env)
        client.initialize()
        resumed = client.call("session/load", sessionId=session, cwd=str(work), mcpServers=mcp)
        assert option(resumed, "model")["currentValue"] == "synthetic/hf:zai-org/GLM-5.3"
        assert option(resumed, "thinking")["currentValue"] == "max"
        reply = client.call("session/prompt", sessionId=session, prompt=[{"type": "text", "text": "ACP_RESUME"}])
        assert reply["stopReason"] == "end_turn"
        assert any("ACP_RESUMED" in str(e) for e in client.events), "resumed prompt returned no result"
    finally:
        if sys.exc_info()[0]:
            client.stderr.seek(0)
            print("ACP fixture diagnostics:", server.errors, client.stderr.read(), file=sys.stderr)
        server.cancel_release.set()
        client.close()
        server.shutdown()
        server.server_close()


MISSING_SYNTHETIC_KEY = "No API key found for synthetic."
STARTUP_MODEL = "synthetic/hf:moonshotai/Kimi-K3"


def missing_synthetic_key(config, home, work):
    # The OpenRouter key stays valid, so a fallback would reach the fixture.
    server, env, _ = endpoint(home)
    client = Acp(config, home, work, {**env, "SYNTHETIC_API_KEY": ""})
    try:
        client.initialize()
        state = client.call("session/new", cwd=str(work), mcpServers=[])
        assert option(state, "model")["currentValue"] == STARTUP_MODEL, state
        reply = client.receive(client.send("session/prompt", {"sessionId": state["sessionId"],
                               "prompt": [{"type": "text", "text": "ACP_EXCHANGE"}]}), allow_error=True)
        assert not server.requests and not server.side_requests, "startup without a Synthetic key fell back to another provider"
        assert MISSING_SYNTHETIC_KEY in json.dumps(reply), reply
        print(f"{'T3' if '--config' in config['commandArgs'] else 'standalone'} ACP without a Synthetic key"
              " stays on Kimi K3 and sends no request")
    finally:
        if sys.exc_info()[0]:
            client.stderr.seek(0)
            print("ACP missing-key diagnostics:", server.errors, client.stderr.read(), file=sys.stderr)
        client.close()
        server.shutdown()
        server.server_close()


INTERACTION_ANSWER = "어떤 작업을 먼저 진행할까요?\n\n1. 문서 검토\n2. 코드 검토"


def interaction(config, home, work, selector, *, standalone=False):
    server, env, _ = endpoint(home)
    client = Acp(config, home, work, env)
    try:
        client.initialize()
        state = client.call("session/new", cwd=str(work), mcpServers=[])
        session = state["sessionId"]
        client.call("session/set_config_option", sessionId=session, configId="model", value=selector)
        reply = client.call("session/prompt", sessionId=session,
                            prompt=[{"type": "text", "text": "ACP_INTERACTION"}])
        assert reply["stopReason"] == "end_turn", (reply, server.errors)
        assert not server.errors, server.errors
        tools = {tool["function"]["name"] for tool in server.requests[0]["tools"]}
        assert ("ask" in tools) == standalone, ("ask availability differs from interaction scope", tools)
        assert "todo" in tools, "interaction scope disabled todo tracking"
        # Tool exchange and final answer are one user turn. A third request
        # means the runtime continued after the answer, without user input.
        assert len(server.requests) == (3 if standalone else 2), (
            "unexpected reminder-driven follow-up", len(server.requests))
        updates = [e["params"]["update"] for e in client.events if e["method"] == "session/update"]
        answers = "".join(u["content"]["text"] for u in updates
                          if u["sessionUpdate"] == "agent_message_chunk" and u["content"]["type"] == "text")
        expected = INTERACTION_ANSWER + ("ACP_REMINDER_CONTINUATION" if standalone else "")
        assert answers == expected, ("unexpected assistant answer or reminder", answers)
        print(f"{selector}: {'standalone ask/reminder controls' if standalone else 'T3 ask absent, todo incomplete, one answer, no reminder'} passed")
    finally:
        if sys.exc_info()[0]:
            client.stderr.seek(0)
            print("ACP interaction diagnostics:", server.errors, client.stderr.read(), file=sys.stderr)
        client.close()
        server.shutdown()
        server.server_close()


OFFLINE_ENV = {"HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
               "ALL_PROXY": "http://127.0.0.1:1", "NO_PROXY": ""}


def import_fake_oauth(command_path, home, providers):
    env = {"HOME": str(home), "PATH": os.environ["PATH"], **OFFLINE_ENV}
    payload = {
        "version": 1,
        "credentials": [
            {
                "provider": provider,
                "credential": {
                    "type": "oauth",
                    "access": f"fake-{provider}-access",
                    "refresh": f"fake-{provider}-refresh",
                    "expires": 4102444800000,
                },
            }
            for provider in providers
        ],
    }
    result = subprocess.run([command_path, "auth", "import", "-"], input=json.dumps(payload),
                            env=env, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)


def raw_bundled_models(command_path, home):
    env = {"HOME": str(home), "PATH": os.environ["PATH"],
           "SYNTHETIC_API_KEY": "sk-fake-synthetic", "OPENROUTER_API_KEY": "sk-fake-openrouter",
           **OFFLINE_ENV}
    result = subprocess.run([command_path, "models", "--json"], cwd=home, env=env,
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)["models"]


def catalog(config, home, work, expected_names):
    expected = set(expected_names)
    client = Acp(config, home, work, OFFLINE_ENV)
    try:
        client.initialize()
        state = client.call("session/new", cwd=str(work), mcpServers=[])
        assert expected == values(state, "model"), ("Unified scope changed selected selectors",
                                                   len(values(state, "model")), sorted(values(state, "model"))[:8],
                                                   sorted(expected - values(state, "model"))[:8],
                                                   sorted(values(state, "model") - expected)[:8])
        actual_names = {row["value"]: row["name"] for row in option(state, "model")["options"]}
        assert actual_names == expected_names, {
            k: (actual_names.get(k), expected_names.get(k))
            for k in sorted(expected) if actual_names.get(k) != expected_names.get(k)
        }
        session = state["sessionId"]
        # T3's custom selectors must all be selectable by the real ACP runtime.
        for selector in sorted(expected):
            state = client.call("session/set_config_option", sessionId=session, configId="model", value=selector)
            assert option(state, "model")["currentValue"] == selector, selector
        state = client.call("session/set_config_option", sessionId=session, configId="model", value="synthetic/hf:zai-org/GLM-5.3")
        assert values(state, "thinking") == {"off", "auto", "low", "high", "max"}, option(state, "thinking")
        state = client.call("session/set_config_option", sessionId=session, configId="thinking", value="max")
        assert option(state, "thinking")["currentValue"] == "max"
        print(f"ACP advertised and selected all {len(expected)} curated selectors; active thinking refreshed")
    finally:
        client.close()


DISABLED = {"openai-codex": "openai-codex/gpt-6-astra",
            "google-antigravity": "google-antigravity/gemini-4-argon"}


def stored_credentials(command_path, home):
    env = {"HOME": str(home), "PATH": os.environ["PATH"], **OFFLINE_ENV}
    result = subprocess.run([command_path, "auth", "export"], env=env,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    return {row["provider"]: row["credential"] for row in json.loads(result.stdout)["credentials"]}


def rejects_disabled(command, home, work, selector):
    provider = selector.split("/", 1)[0]
    result = subprocess.run(command, input="", cwd=work,
                            env={"HOME": str(home), "PATH": os.environ["PATH"], **OFFLINE_ENV},
                            capture_output=True, text=True, timeout=20)
    assert result.returncode != 0 and f'Provider "{provider}" is disabled.' in result.stderr, (selector, result.stderr)


def standalone_cli_scope(entry, api, api_expected_names):
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        work = prepare(entry, home)
        import_fake_oauth(api["commandPath"], home, tuple(DISABLED))
        credentials = stored_credentials(api["commandPath"], home)
        assert set(credentials) == set(DISABLED), credentials
        config_path = home / ".omp/agent/config.yml"
        common = config_path.read_bytes()
        control = json.loads(common)
        control["disabledProviders"] = [p for p in control["disabledProviders"] if p not in DISABLED]
        config_path.write_text(json.dumps(control))
        try:
            raw = raw_bundled_models(api["commandPath"], home)
        finally:
            config_path.write_bytes(common)
        raw_selectors = {row["selector"] for row in raw}
        # Without the managed exclusion the fake logins expose both providers,
        # so the checks below prove disabledProviders, not missing auth.
        assert set(DISABLED.values()) <= raw_selectors, sorted(s for s in raw_selectors if s.split("/")[0] in DISABLED)
        assert any(s.startswith("openrouter/") and not s.startswith("openrouter/openrouter/")
                   for s in raw_selectors), "raw catalog missing uncurated OpenRouter vendor controls"
        # Standalone OMP without T3's --config/--models/--model must enforce ~/.omp/agent/config.yml.
        standalone = {"commandPath": api["commandPath"], "commandArgs": ["--mode", "acp"]}
        client = Acp(standalone, home, work, OFFLINE_ENV)
        try:
            client.initialize()
            state = client.call("session/new", cwd=str(work), mcpServers=[])
            assert option(state, "model")["currentValue"] == STARTUP_MODEL, state
            assert option(state, "thinking")["currentValue"] == "high", option(state, "thinking")
            session = state["sessionId"]
            assert values(state, "model") == set(api_expected_names), (
                sorted(values(state, "model") - set(api_expected_names))[:8],
                sorted(set(api_expected_names) - values(state, "model"))[:8],
            )
            for selector in DISABLED.values():
                rejected = client.receive(client.send(
                    "session/set_config_option", {"sessionId": session, "configId": "model",
                                                  "value": selector}), allow_error=True)
                assert "error" in rejected, ("ACP accepted a disabled provider", selector)
            assert option(client.call("session/set_config_option", sessionId=session, configId="thinking",
                                      value="high"), "model")["currentValue"] == STARTUP_MODEL
        finally:
            client.close()
        widened = json.loads(common)
        widened["enabledModels"] += [provider + "/*" for provider in DISABLED]
        config_path.write_text(json.dumps(widened))
        for selector in DISABLED.values():
            rejects_disabled([api["commandPath"], "--no-extensions", "--no-session", "--model", selector, "-p", "smoke"],
                             home, work, selector)
        assert stored_credentials(api["commandPath"], home) == credentials, "disabling a provider changed its stored login"
    # Also verify T3's ACP command isolates T3 sessions when ~/.omp/agent/config.yml drifts wider.
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        work = prepare(entry, home)
        drifted = json.loads((home / ".omp/agent/config.yml").read_text())
        drifted["enabledModels"] = ["synthetic/**", "openrouter/**", *(provider + "/**" for provider in DISABLED)]
        drifted["disabledProviders"] = []
        (home / ".omp/agent/config.yml").write_text(json.dumps(drifted))
        import_fake_oauth(api["commandPath"], home, tuple(DISABLED))
        catalog(api, home, work, api_expected_names)
        for selector in DISABLED.values():
            pinned_args = list(api["commandArgs"])
            pinned_args[pinned_args.index("--model") + 1] = selector
            rejects_disabled([api["commandPath"], *pinned_args], home, work, selector)

def applied(entry, home):
    target = home / ".t3/userdata/settings.json"
    target.parent.mkdir(parents=True)
    seed = {"providerInstances": {"pi": {"enabled": True, "config": {"preserved": "Pi state"}},
                                   "omp": {"environment": {"variables": {"KEEP": "yes"}},
                                           "config": {"authMethodId": "agent", "customModels": ["stale-selector"]}},
                                   "omp-codex": {"driver": "acpRegistry", "enabled": True,
                                                 "config": {"authMethodId": "agent"}}},
            "providerModelPreferences": {"omp": {"hiddenModels": ["synthetic/hf:moonshotai/Kimi-K3"],
                                                 "modelOrder": ["openai-codex/gpt-6-astra"]}},
            "projectSettingsOverrides": {"example": {"keep": True}}}
    target.write_text(json.dumps(seed))
    script = entry["activation"].replace(entry["home"], str(home))
    assert script != entry["activation"], "T3 settings activation has no expected destination"
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", 'run() { "$@"; }\n' + script],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    settings = json.loads(target.read_text())
    assert settings["projectSettingsOverrides"] == seed["projectSettingsOverrides"]
    assert settings["providerModelPreferences"] == {
        "omp": {"hiddenModels": ["synthetic/hf:moonshotai/Kimi-K3", "default"],
                "modelOrder": ["openai-codex/gpt-6-astra"]}
    }, settings.get("providerModelPreferences")
    instances = settings["providerInstances"]
    assert instances["pi"]["enabled"] is False, "T3 still enables retired Pi"
    assert instances["pi"]["config"] == seed["providerInstances"]["pi"]["config"]
    assert instances["omp"]["environment"] == seed["providerInstances"]["omp"]["environment"]
    assert instances["omp"]["config"]["authMethodId"] == "agent"
    assert "omp-codex" not in instances, "T3 retained the retired OMP Codex entry"
    assert instances["omp"]["driver"] == "acpRegistry" and instances["omp"]["enabled"] is True
    assert instances["omp"]["config"]["source"] == "local"
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", 'run() { "$@"; }\n' + script],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(target.read_text()) == settings, "repeated activation changed consolidated settings"
    return instances


if __name__ == "__main__":
    deliveries, synthetic, openrouter = sys.argv[1:]
    entries = json.loads(Path(deliveries).read_text())
    assert entries, "no T3-enabled host tested"
    expected_names = {
        f"{provider}/{row['id']}": (
            row["display_name"] + " (infinite)"
            if provider == "synthetic" and row["id"].startswith("infinite:")
            and not row["display_name"].endswith(" (infinite)")
            else (row["display_name"] if provider == "synthetic" else row["name"].removeprefix("OpenRouter: "))
        )
        for provider, path in (("synthetic", synthetic), ("openrouter", openrouter))
        for row in json.loads(Path(path).read_text())["data"]
        if provider == "synthetic" or (row["id"].startswith("openrouter/")
                                       and row["id"] != "openrouter/bodybuilder")
    }
    expected = set(expected_names)
    for entry in entries:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            instances = applied(entry, home)
            api = instances["omp"]["config"]
            assert set(api["customModels"]) == expected and len(api["customModels"]) == len(expected), "T3 API selectors capped or changed"
            patterns = expected
            args = api["commandArgs"]
            assert set(args[args.index("--models") + 1].split(",")) == patterns, "CLI scope differs from unified selection"
            assert args[args.index("--model") + 1] == STARTUP_MODEL
            assert args[args.index("--thinking") + 1] == "high"
            overlay = json.loads(Path(args[args.index("--config") + 1]).read_text())
            assert set(overlay["enabledModels"]) == patterns, "overlay scope differs from unified selection"
            assert overlay["modelRoles"]["default"] == STARTUP_MODEL
            assert overlay["modelRoles"]["web"] == "web/synthetic"
            assert overlay["defaultThinkingLevel"] == "high"
            assert overlay["task"]["enableEffort"] is True and overlay["task"]["maxEffort"] == "high"
            assert overlay["github"] == {"enabled": True}
            assert overlay["task"]["agentModelOverrides"]["architect"] == STARTUP_MODEL + ":high"
            work = prepare(entry, home)
            common = (home / ".omp/agent/config.yml").read_bytes()
            assert overlay["skills"]["customDirectories"] == json.loads(common.decode())["skills"]["customDirectories"]
            assert set(json.loads(common.decode())["enabledModels"]) == patterns, "common CLI config.yml missing curated enabledModels"
            catalog(api, home, work, expected_names)
            exchange(api, home, work)
            missing_synthetic_key(api, home, work)
            missing_synthetic_key({"commandPath": api["commandPath"], "commandArgs": ["--mode", "acp"]}, home, work)
            interaction(api, home, work, "synthetic/hf:zai-org/GLM-5.3")
            interaction({"commandPath": api["commandPath"], "commandArgs": ["--mode", "acp"]},
                        home, work, "synthetic/hf:zai-org/GLM-5.3", standalone=True)
            standalone_cli_scope(entry, api, expected_names)
            print("ACP prompt/native tool/MCP result/cancel/persistent resume and standalone CLI scope passed")
            assert (home / ".omp/agent/config.yml").read_bytes() == common, "ACP scope changed common CLI settings"
