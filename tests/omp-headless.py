"""Capture real OMP requests and complete a deterministic tool exchange, offline.

The pinned Synthetic shim replaces baseUrl with its official URL. A local TLS
proxy exercises that transport without changing provider identities or metadata.
"""

import http.server
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import ssl
import sys
import tempfile
import threading


OMP, MANIFEST, MISSING_KEY, CONTEXTS, CE_SOURCE = sys.argv[1:]
documents = json.loads(Path(MANIFEST).read_text())
assert documents, "no managed OMP documents were tested"
requests = []
context_steps = None
context_results = []
context_errors = []
child_receipt = {
    "reviewer": "deterministic protocol fixture",
    "findings": [{"title": "fixture finding", "evidence": "disposable repository"}],
    "residual_risks": ["authenticated peer behavior remains unverified"],
    "testing_gaps": ["serving-family independence is unverified"],
    "cross_model_route": "deterministic-fixture",
    "model_requested": "synthetic/hf:zai-org/GLM-5.3", "effort_requested": "max",
    "receipt_supported": False,
    "model_actual": "unverified", "effort_actual": "unverified",
    "independence_verified": False,
}
certificate_dir = tempfile.TemporaryDirectory()
cert = Path(certificate_dir.name) / "cert.pem"
key = Path(certificate_dir.name) / "key.pem"
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-keyout", str(key), "-out", str(cert), "-subj", "/CN=OMP test provider",
                "-addext", "subjectAltName=DNS:api.synthetic.new,DNS:openrouter.ai"],
               check=True, capture_output=True)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(cert, key)


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        if self.path not in ("api.synthetic.new:443", "openrouter.ai:443"):
            self.send_response(502)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.connection = tls.wrap_socket(self.connection, server_side=True)
        self.rfile = self.connection.makefile("rb")
        self.wfile = self.connection.makefile("wb")
        self.close_connection = False
        self.handle_one_request()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append((self.path, body, self.headers.get("Authorization")))
        if self.path == "/v2/search":
            assert self.headers.get("Authorization") == "Bearer sk-fake-synthetic"
            assert body["query"] == "OMP_CONTEXT_SEARCH"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"results": [{"url": f"http://127.0.0.1:{server.server_port}/page",
                                                       "title": "OMP_SEARCH_PROOF", "text": "Search fixture"}]}).encode())
            return
        if self.path.endswith("/responses"):
            self.respond_responses(body)
            return
        if "messages" not in body:
            self.send_error(404)
            return
        has_result = any(m.get("role") == "tool" for m in body["messages"])
        if context_steps is not None:
            try:
                delta, reason = self.context_response(body)
            except AssertionError as error:
                context_errors.append(str(error))
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": {"message": str(error)}}).encode())
                return
        elif has_result:
            delta = {"content": "OMP_PROVIDER_OK"}
            reason = "stop"
        else:
            delta = {"tool_calls": [{"index": 0, "id": "call_write", "type": "function",
                                    "function": {"name": "write", "arguments": json.dumps({
                                        "i": "Writing provider proof", "path": "provider-proof.txt",
                                        "content": "tool exchange completed\n"})}}]}
            reason = "tool_calls"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for payload in ({"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
                        {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]}):
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

    def do_GET(self):
        if self.path != "/page":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<html><body><p>OMP_FETCH_PROOF</p></body></html>")

    def context_response(self, body):
        tools = {tool["function"]["name"] for tool in body.get("tools", [])}
        child = any(m["role"] == "user" and "Return the requested review fixture through yield." in str(m.get("content"))
                    for m in body["messages"])
        # OMP compresses each skill description in a background one-shot request
        # to the session model; it carries no session context.
        if not tools and len(body["messages"]) == 1 and str(body["messages"][0].get("content")).startswith(
                "Compress into one routing hint"):
            return {"content": "fixture routing hint"}, "stop"
        if child:
            assert "yield" in tools, "structured child has no yield tool"
            name, arguments = "yield", {"data": child_receipt}
        else:
            system = str(body["messages"])
            assert "OMP_REPO_INSTRUCTION" in system, "repository instruction absent from provider context"
            assert "GPG and encryption" in system, "shared personal instructions absent"
            assert "OMP tools and Compound Engineering" in system, "native tool guide absent"
            assert "OMP role orchestration" in system, "OMP role orchestration policy absent"
            assert "test-audit" in system and "ce-code-review" in system, "contributed/CE skills absent"
            results = [m for m in body["messages"] if m["role"] == "tool"]
            if results:
                context_results.append(str(results[-1]["content"]))
            if len(results) >= len(context_steps):
                return {"content": "OMP_CONTEXT_OK"}, "stop"
            name, arguments = context_steps[len(results)]
            assert name in tools, (name, sorted(tools))
        return {"tool_calls": [{"index": 0, "id": f"context_{len(context_results)}", "type": "function",
                                  "function": {"name": name, "arguments": json.dumps(arguments)}}]}, "tool_calls"

    def respond_responses(self, body):
        has_result = any(m.get("type") == "function_call_output" for m in body["input"])
        arguments = json.dumps({"i": "Writing provider proof", "path": "provider-proof.txt",
                                "content": "tool exchange completed\n"})
        item = ({"type": "message", "id": "msg_test", "role": "assistant", "status": "completed",
                 "content": [{"type": "output_text", "text": "OMP_PROVIDER_OK", "annotations": []}]}
                if has_result else {"type": "function_call", "id": "fc_test", "call_id": "call_write",
                                    "name": "write", "arguments": arguments, "status": "completed"})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        response = {"id": "resp_test", "object": "response", "model": body["model"], "status": "in_progress", "output": []}
        initial_item = {**item, **({"content": []} if has_result else {"arguments": ""})}
        events = [("response.created", {"response": response}),
                  ("response.output_item.added", {"output_index": 0, "item": initial_item})]
        if has_result:
            events += [("response.content_part.added", {"item_id": item["id"], "output_index": 0, "content_index": 0,
                                                        "part": {"type": "output_text", "text": "", "annotations": []}}),
                       ("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0,
                                                        "delta": "OMP_PROVIDER_OK"})]
        else:
            events += [("response.function_call_arguments.delta", {"item_id": item["id"], "output_index": 0, "delta": arguments})]
        events += [("response.output_item.done", {"output_index": 0, "item": item}),
                   ("response.completed", {"response": {**response, "status": "completed", "output": [item],
                                                         "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}})]
        for kind, payload in events:
            self.wfile.write(("event: " + kind + "\ndata: " + json.dumps({"type": kind, **payload}) + "\n\n").encode())


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    for declared in documents:
        for selector, model, effort in (("synthetic/hf:zai-org/GLM-5.3:max", "hf:zai-org/GLM-5.3", "max"),
                                        ("synthetic/hf:zai-org/GLM-5.3:low", "hf:zai-org/GLM-5.3", "low"),
                                        ("openrouter/openai/gpt-4o", "openai/gpt-4o", None),
                                        ("missing", "hf:zai-org/GLM-5.3", None)):
            with tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary)
                agent = home / ".omp/agent"
                agent.mkdir(parents=True)
                work = home / "project"
                work.mkdir()
                models = json.loads(Path(declared["models.yml"]).read_text())
                for name in ("synthetic", "openrouter"):
                    provider = models["providers"][name]
                    # Give only the protected command a fake credential, not OMP or its tools.
                    variable = "SYNTHETIC_API_KEY" if name == "synthetic" else "OPENROUTER_API_KEY"
                    provider["apiKey"] = ("!" + MISSING_KEY if selector == "missing" else
                                          f"!{variable}=sk-fake-{name} " + provider["apiKey"][1:])
                (agent / "models.yml").write_text(json.dumps(models))
                (agent / "config.yml").write_bytes(Path(declared["config.yml"]).read_bytes())
                env = {"HOME": str(home), "PATH": os.environ["PATH"],
                       "PI_CODING_AGENT_DIR": str(agent), "NODE_EXTRA_CA_CERTS": str(cert),
                       "PI_PROXY_SYNTHETIC": f"http://127.0.0.1:{server.server_port}",
                       "PI_PROXY_OPENROUTER": f"http://127.0.0.1:{server.server_port}"}
                args = [OMP, "--print", "--mode", "json", "--no-session", "--no-title", "--no-lsp",
                        "--no-extensions", "--no-skills", "--no-rules", "--tools", "write", "--auto-approve"]
                args += ["--model", "synthetic/hf:zai-org/GLM-5.3:max" if selector == "missing" else selector]
                requests.clear()
                try:
                    result = subprocess.run([*args, "Write provider-proof.txt, then finish."],
                                            cwd=work, env=env, stdin=subprocess.DEVNULL,
                                            capture_output=True, text=True, timeout=30)
                except subprocess.TimeoutExpired as error:
                    raise AssertionError(([(path, body.get("model")) for path, body, _ in requests],
                                          error.stdout, error.stderr)) from error
                if selector == "missing":
                    assert result.returncode != 0, "OMP accepted absent provider credentials"
                    assert not requests, "OMP sent a request without its provider key"
                    assert "sk-fake-" not in result.stdout + result.stderr, "credential leaked in failure"
                    continue
                assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
                assert len(requests) == 2, (len(requests), result.stdout, result.stderr)
                for path, body, auth in requests:
                    expected_path = "/api/v1/responses" if selector and selector.startswith("openrouter/") else "/openai/v1/chat/completions"
                    assert path == expected_path, path
                    assert body["model"] == model, body["model"]
                    if effort:
                        assert body.get("reasoning_effort") == effort, body.get("reasoning_effort")
                    expected_key = "sk-fake-openrouter" if selector and selector.startswith("openrouter/") else "sk-fake-synthetic"
                    assert auth == f"Bearer {expected_key}", "protected key command did not supply the request"
                assert (work / "provider-proof.txt").read_text() == "tool exchange completed\n"
                assert "OMP_PROVIDER_OK" in result.stdout, result.stdout
        print("OMP explicit Synthetic max/low and OpenRouter tool exchanges passed")
    for entry in json.loads(Path(CONTEXTS).read_text()):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            agent = home / ".omp/agent"
            shutil.copytree(Path(entry["files"]) / ".omp/agent", agent, symlinks=True)
            assert not (agent / "OMP.md").exists(), "retired OMP.md was materialized"
            assert (agent / "agents/architect.md").is_file(), "P6 architect agent was not materialized"
            for directory, _, _ in os.walk(agent):
                Path(directory).chmod(0o755)
            # Native hosts generate the personal prompt during apply.
            script = Path(entry["activate"]).read_text()
            step = re.search(r'_iNote "Activating %s" "agentInstructions"\n(.*?)(?=\n_iNote|\Z)',
                             script, re.S)
            if step:
                subprocess.run(["bash", "-eu", "-c", step.group(1)], check=True,
                               env={"HOME": str(home), "PATH": os.environ["PATH"],
                                    "XDG_CONFIG_HOME": str(home / ".config"),
                                    "XDG_CONFIG_DIRS": str(home / "xdg-defaults")})
            # A complete tree preserves scripts and relative references, not just SKILL.md.
            delivered_ce = agent / "plugins/compound-engineering"
            for source in Path(CE_SOURCE).rglob("*"):
                if source.is_file():
                    assert (delivered_ce / source.relative_to(CE_SOURCE)).read_bytes() == source.read_bytes()
            work = home / "project"
            work.mkdir()
            subprocess.run(["git", "init", "-q", str(work)], check=True)
            (work / "AGENTS.md").write_text("# OMP_REPO_INSTRUCTION\nWrite context-proof.txt after following the context-proof skill.\n")
            # Additional disposable skill, beside the actual store-backed contributed root.
            skill_root = home / "fixture-skills"
            skill = skill_root / "context-proof"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text("---\nname: context-proof\ndescription: Exercise OMP native skill assets\n---\nRead proof.txt beside this file, then write its value to context-proof.txt.\n")
            (skill / "proof.txt").write_text("OMP_SKILL_ASSET_PROOF\n")
            config = json.loads(Path(entry["documents"]["config.yml"]).read_text())
            directories = config["skills"]["customDirectories"]
            assert directories, "no managed CE skill directory"
            config["skills"]["customDirectories"] = [p.replace(entry["home"], str(home), 1) for p in directories] + [str(skill_root)]
            # Synchronous dispatch makes the terminal artifact observable before process exit.
            config["async"] = {"enabled": False}
            assert config["github"]["enabled"] is True
            assert config["modelRoles"]["default"] == "synthetic/hf:moonshotai/Kimi-K3"
            assert config["task"]["enableEffort"] is True and config["task"]["maxEffort"] == "high"
            assert config["task"]["agentModelOverrides"]["architect"] == "synthetic/hf:moonshotai/Kimi-K3:high"
            # Native children inherit the explicit API fixture's model role in offline tests.
            config["modelRoles"] = {"default": "synthetic/hf:zai-org/GLM-5.3", "web": "web/synthetic"}
            config["task"]["agentModelOverrides"] = {}
            config["defaultThinkingLevel"] = "max"
            (agent / "config.yml").write_text(json.dumps(config))
            models = json.loads(Path(entry["documents"]["models.yml"]).read_text())
            models["providers"]["synthetic"]["apiKey"] = "!SYNTHETIC_API_KEY=sk-fake-synthetic " + models["providers"]["synthetic"]["apiKey"][1:]
            (agent / "models.yml").write_text(json.dumps(models))
            context_results.clear()
            requests.clear()
            context_steps = [
                ("read", {"path": "skill://context-proof"}),
                ("read", {"path": str(skill / "proof.txt")}),
                ("write", {"path": "context-proof.txt", "content": (skill / "proof.txt").read_text(), "i": "Follow repository and skill instructions"}),
                ("read", {"path": "skill://test-audit"}),
                ("read", {"path": "skill://ce-work/references/implementation-loop.md"}),
                ("read", {"path": "history://"}),
                ("web_search", {"query": "OMP_CONTEXT_SEARCH"}),
                ("read", {"path": f"http://127.0.0.1:{server.server_port}/page"}),
                ("task", {"context": "Explicit fixture review; retain all schema fields and uncertainty.", "tasks": [
                    {"name": "ContextPeer", "agent": "task", "task": "Return the requested review fixture through yield.",
                     "outputSchema": {"type": "object", "properties": {
                         "reviewer": {"type": "string"}, "findings": {"type": "array"},
                         "residual_risks": {"type": "array"}, "testing_gaps": {"type": "array"},
                         "model_actual": {"type": "string"}, "effort_actual": {"type": "string"},
                         "cross_model_route": {"type": "string"}, "model_requested": {"type": "string"},
                         "effort_requested": {"type": "string"}, "receipt_supported": {"type": "boolean"},
                         "independence_verified": {"type": "boolean"}},
                         "required": list(child_receipt)},
                     "solutionSpace": "Inspect the disposable repository only."}]}),
                ("read", {"path": "agent://ContextPeer"}),
                ("task", {"context": "A missing agent must fail without a completed receipt.", "tasks": [
                    {"name": "FailedPeer", "agent": "missing-context-agent", "task": "Return a review receipt.",
                     "solutionSpace": "This dispatch must fail preflight."}]}),
                ("read", {"path": "agent://FailedPeer"}),
            ]
            env = {"HOME": str(home), "PATH": os.environ["PATH"], "PI_CODING_AGENT_DIR": str(agent),
                   "NODE_EXTRA_CA_CERTS": str(cert), "HTTPS_PROXY": f"http://127.0.0.1:{server.server_port}",
                   "PI_PROXY_SYNTHETIC": f"http://127.0.0.1:{server.server_port}"}
            result = subprocess.run([OMP, "--print", "--mode", "json", "--no-title", "--no-lsp", "--no-extensions",
                                     "--model", "synthetic/hf:zai-org/GLM-5.3:max",
                                     "--tools", "read,write,web_search,task", "--auto-approve", "Exercise OMP_CONTEXT_PROOF."],
                                    cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
            assert not context_errors, context_errors
            assert result.returncode == 0, (result.returncode, result.stdout[-12000:], result.stderr)
            assert "OMP_CONTEXT_OK" in result.stdout, result.stdout[-12000:]
            assert len(context_results) == len(context_steps), context_results
            for index, marker in ((0, "proof.txt"), (1, "OMP_SKILL_ASSET_PROOF"), (3, "Authoring gate"),
                                  (4, "Build what was asked"), (6, "OMP_SEARCH_PROOF"),
                                  (7, "OMP_FETCH_PROOF"), (9, "fixture finding"),
                                  (10, "missing-context-agent"), (11, "Not found")):
                assert marker in context_results[index], (index, context_results[index])
            assert (work / "context-proof.txt").read_text() == "OMP_SKILL_ASSET_PROOF\n"
            artifacts = list(agent.rglob("ContextPeer.md"))
            assert artifacts, "native child did not produce a terminal artifact"
            receipt = json.loads(artifacts[0].read_text())
            assert receipt == child_receipt, receipt
            assert not list(agent.rglob("FailedPeer.json")), "failed dispatch published a review receipt"
            assert not list(agent.rglob("FailedPeer.md")), "failed dispatch published a terminal artifact"
            assert "sk-fake-" not in result.stdout + result.stderr, "tool transcript leaked credentials"
            context_steps = None
    print("OMP context, native search/fetch, and terminal child artifacts passed (fake provider; independence unverified)")
finally:
    server.shutdown()
    server.server_close()
    thread.join()
    certificate_dir.cleanup()
