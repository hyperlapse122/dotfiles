"""Apply committed Codex/CE pins and inspect native discovery in disposable state.

No OAuth or personal credentials are used. Native skill expansion is checked
separately from model completion; missing expansion proof fails this smoke.
"""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time
import tomllib

from asset_fixtures import copy_asset_templates, harness_skill_names
from smoke_personal_apps import REPO, check_version, executable, run, temporary_destination


class AppServer:
    def __init__(self, command, env, cwd, stderr):
        self.process = subprocess.Popen(command, env=env, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr, text=True,
                                        encoding="utf-8", errors="backslashreplace")
        self.messages = queue.Queue()
        self.events = []
        self.sequence = 0
        self.reader = threading.Thread(target=self.read_messages, daemon=True)
        self.reader.start()

    def read_messages(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put(error)
        finally:
            self.messages.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, timeout):
        try:
            message = self.messages.get(timeout=timeout)
        except queue.Empty as error:
            raise RuntimeError("Timed out waiting for native Codex app-server") from error
        if message is None:
            raise RuntimeError("Native Codex app-server closed unexpectedly")
        if isinstance(message, Exception):
            raise message
        self.events.append(message)
        if "method" in message and "id" in message:
            self.send({"id": message["id"], "error": {"code": -32601, "message": "No interactive approvals in isolated smoke"}})
        return message

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            message = self.receive(max(0.1, deadline - time.monotonic()))
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"Native {method} rejected: {message['error']}")
                return message["result"]
        raise RuntimeError(f"Native {method} did not respond")

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=10)
        self.reader.join(timeout=5)
        self.process.stdout.close()


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


@contextmanager
def capture_requests():
    requests = []

    class CaptureHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            # Capture only: never manufacture a model response or completion.
            body = b'{"error":{"message":"Intentional capture-only endpoint; no model execution"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), CaptureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/v1", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-target")
    args = parser.parse_args()
    chezmoi = executable("chezmoi")
    pins = json.loads((REPO / "home/.chezmoidata/personal-app-lock.json").read_text(encoding="utf-8"))
    ce_pin = json.loads((REPO / "home/.chezmoidata/harness-plugin-lock.json").read_text(encoding="utf-8"))["harnessPluginLocks"]["compound-engineering"]
    with temporary_destination() as scratch:
        root = Path(scratch)
        home, source, outside = (root / name for name in ("home ' 한글", "source", "neutral"))
        for directory in (home, source, outside):
            directory.mkdir()
        # A neutral repository root bounds project instruction/skill discovery.
        (outside / ".git").mkdir()
        for relative in (
            ".chezmoidata", ".chezmoitemplates", ".chezmoiignore", "private_dot_codex",
            ".chezmoiscripts/run_after_25-codex-plugins.sh.tmpl",
            ".chezmoiscripts/run_after_25-codex-plugins.ps1.tmpl",
        ):
            origin, destination = REPO / "home" / relative, source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if origin.is_dir():
                shutil.copytree(origin, destination)
            else:
                shutil.copy2(origin, destination)
        declarations_path = source / ".chezmoidata/personal-apps.json"
        declarations = json.loads(declarations_path.read_text(encoding="utf-8"))
        declarations["personalApps"] = {"codex": declarations["personalApps"]["codex"]}
        declarations_path.write_text(json.dumps(declarations), encoding="utf-8")
        (source / ".chezmoitemplates/agent-instructions").write_text(
            'codex-smoke-common-instructions\n'
            '{{ if eq .harness "codex" }}codex-smoke-native-instructions{{ end }}\n'
            '{{ if eq .harness "omp" }}codex-smoke-foreign-instructions{{ end }}\n', encoding="utf-8")
        copy_asset_templates(source, ('personal-apps', 'codex-package', 'harness-plugins', 'harness-skills'))
        config = root / "chezmoi.toml"
        config_text = ""
        if os.name == "nt":
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config_text = ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
                           '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config.write_text(config_text, encoding="utf-8")
        env = {key: value for key, value in os.environ.items()
               if not key.upper().startswith(("CODEX_", "OPENAI_", "AZURE_", "ANTHROPIC_", "AWS_"))}
        env.update({
            "HOME": str(home), "USERPROFILE": str(home), "CODEX_HOME": str(home / ".codex"),
            "APPDATA": str(root / "config"), "LOCALAPPDATA": str(root / "local"),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "NO_COLOR": "1",
        })
        command = [chezmoi, "--config", str(config), "--source", str(source),
                   "--destination", str(home), "--cache", str(root / "chezmoi-cache"),
                   "--persistent-state", str(root / "chezmoi-state.boltdb"), "--no-tty"]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in pins["personalAppLocks"]["codex"]["targets"]:
            raise RuntimeError(f"No committed Codex package for {target}")
        chez("apply", "--force", "--exclude=scripts")
        binary = home / ".local/bin" / ("codex.exe" if os.name == "nt" else "codex")
        # Never use an OS keyring even if this host has an existing Codex login.
        native = [str(binary), "-c", 'cli_auth_credentials_store="file"']

        def codex(*arguments):
            return run(native + list(arguments), env=env, cwd=outside)

        version = codex("--version")
        check_version(version, pins["personalAppLocks"]["codex"]["tag"])
        managed = home / ".local/share/dotfiles/harness-plugins/compound-engineering"
        original_skill = (managed / "skills/ce-plan/SKILL.md").read_bytes()
        settings_path = home / ".codex/config.toml"
        # These unowned settings also scope hook invocations to a file-only login.
        settings_path.write_text('cli_auth_credentials_store = "file"\n' + settings_path.read_text(encoding="utf-8"), encoding="utf-8")
        chez("apply", "--force")
        plugin_id = "compound-engineering@compound-engineering-plugin"
        installed = json.loads(codex("plugin", "list", "--marketplace", "compound-engineering-plugin", "--json"))["installed"]
        ce = next(item for item in installed if item["pluginId"] == plugin_id)
        if not ce["enabled"] or not Path(ce["marketplaceSource"]["source"]).samefile(managed):
            raise RuntimeError("Native CE is not enabled from the pinned local tree")
        # Install a real independent local plugin, not a substitute for CE.
        unrelated = root / "unrelated"
        (unrelated / ".agents/plugins").mkdir(parents=True)
        (unrelated / ".codex-plugin").mkdir()
        (unrelated / ".agents/plugins/marketplace.json").write_text(json.dumps({
            "name": "smoke-unrelated", "plugins": [{"name": "smoke-unrelated", "source": {"source": "local", "path": "./"}}],
        }), encoding="utf-8")
        (unrelated / ".codex-plugin/plugin.json").write_text(json.dumps({"name": "smoke-unrelated", "version": "1.0.0"}), encoding="utf-8")
        codex("plugin", "marketplace", "add", str(unrelated))
        other_install = json.loads(codex("plugin", "add", "smoke-unrelated@smoke-unrelated", "--json"))
        ce_install = json.loads(codex("plugin", "add", plugin_id, "--json"))
        cached_skill = Path(ce_install["installedPath"]) / "skills/ce-plan/SKILL.md"
        if cached_skill.read_bytes() != original_skill:
            raise RuntimeError("Native CE cache differs from the committed archive")
        text = settings_path.read_text(encoding="utf-8")
        text = text.replace("enabled = true", "enabled = false")
        settings_path.write_text('check_for_update_on_startup = true\n' +
                                 '\n'.join(line for line in text.splitlines() if not line.startswith("check_for_update_on_startup =")) +
                                 '\n[history]\nmax_bytes = 12345\n', encoding="utf-8")
        (managed / "skills/ce-plan/SKILL.md").write_text("managed source drift", encoding="utf-8")
        cached_skill.write_text("native cache drift", encoding="utf-8")
        chez("apply", "--force")
        settings = tomllib.loads(settings_path.read_text(encoding="utf-8"))
        if settings["check_for_update_on_startup"] is not False or settings["plugins"][plugin_id]["enabled"] is not True:
            raise RuntimeError("Reapply did not restore managed settings")
        if settings["history"]["max_bytes"] != 12345:
            raise RuntimeError("Reapply discarded an unrelated configuration table")
        if settings["plugins"]["smoke-unrelated@smoke-unrelated"]["enabled"] is not False:
            raise RuntimeError("Reapply changed unrelated plugin enablement")
        if settings["plugins"]["_default"]["enabled"] is not False:
            raise RuntimeError("Rendered config does not turn off plugins that have no entry")
        if not Path(other_install["installedPath"]).is_dir():
            raise RuntimeError("Reapply removed the unrelated plugin")
        if cached_skill.read_bytes() != original_skill or (managed / "skills/ce-plan/SKILL.md").read_bytes() != original_skill:
            raise RuntimeError("Reapply did not restore pinned source and native cache")
        prompt = codex("debug", "prompt-input", "Inspect native user instructions without executing tools.")
        for marker in ("codex-smoke-common-instructions", "codex-smoke-native-instructions"):
            if marker not in prompt:
                raise RuntimeError("Native prompt is missing " + marker)
        if "codex-smoke-foreign-instructions" in prompt:
            raise RuntimeError("Native prompt includes foreign harness instructions")
        print(f"Native {target}: {version}; CE {ce_pin['tag']} ({ce_pin['commit']})")
        print("Verified: private configuration, native instructions, pinned local marketplace, same-pin cache repair, unrelated plugin/config preservation")

        invocation_error = None
        events = []
        with capture_requests() as (endpoint, requests), (root / "app-server.stderr").open("w", encoding="utf-8") as stderr:
            capture_native = native + [
                "-c", 'model_provider="smoke_capture"',
                "-c", 'model="gpt-5.1-codex"',
                "-c", 'model_providers.smoke_capture.name="Capture-only local endpoint"',
                "-c", "model_providers.smoke_capture.base_url=" + json.dumps(endpoint),
                "-c", 'model_providers.smoke_capture.wire_api="responses"',
                "-c", "model_providers.smoke_capture.requires_openai_auth=false",
                "-c", "model_providers.smoke_capture.request_max_retries=0",
                "-c", "model_providers.smoke_capture.stream_max_retries=0",
            ]
            server = AppServer(capture_native + ["app-server"], env, outside, stderr)
            try:
                server.request("initialize", {"clientInfo": {"name": "dotfiles-codex-smoke", "version": "1.0"},
                                              "capabilities": {"experimentalApi": True}})
                server.send({"method": "initialized", "params": {}})
                listing = server.request("skills/list", {"cwds": [str(outside)], "forceReload": True})
                skills = [skill for entry in listing["data"] for skill in entry["skills"]]
                skill = next((item for item in skills if item["name"] == "compound-engineering:ce-plan" and item.get("pluginId") == plugin_id and item["enabled"]), None)
                if skill is None or Path(skill["path"]).read_bytes() != original_skill:
                    raise RuntimeError("Native app-server skills/list did not discover pinned CE ce-plan")
                if not any(item["name"] == "compound-engineering:ce-noslop" and item.get("pluginId") == plugin_id
                           and item["enabled"] for item in skills):
                    raise RuntimeError("Native app-server skills/list lost CE ce-noslop under the plugin allowlist")
                print("Verified: under plugins._default enabled = false, native app-server skills/list discovers enabled pinned CE ce-plan and ce-noslop")
                if os.name == "nt":
                    missing = [name for name in harness_skill_names()
                               if not (home / ".agents/skills" / name / "SKILL.md").is_file()]
                    if missing:
                        raise RuntimeError("Shared skills are missing from the disposable ~/.agents/skills: " + repr(missing))
                    print("Verified: shared skills placed in the disposable ~/.agents/skills. "
                          "Discovery count skipped on Windows: Codex resolves ~/.agents/skills from the OS profile "
                          "and ignores HOME and USERPROFILE, so it would count the real profile instead.")
                else:
                    for name in harness_skill_names():
                        found = [item["path"] for item in skills if item["name"] == name]
                        if len(found) != 1:
                            raise RuntimeError(f"Native shared skill {name} is missing or duplicated: {found}")
                    print("Verified: native app-server skills/list discovers each shared skill exactly once")
                thread = server.request("thread/start", {"cwd": str(outside), "approvalPolicy": "never", "sandbox": "read-only"})
                if not any(Path(path).samefile(home / ".codex/AGENTS.md") for path in thread["instructionSources"]):
                    raise RuntimeError("Native thread did not discover user-scope AGENTS.md")
                try:
                    server.request("turn/start", {"threadId": thread["thread"]["id"], "input": [
                        {"type": "skill", "name": skill["name"], "path": skill["path"]},
                        {"type": "text", "text": "Use the explicitly selected skill to explain its purpose. Do not execute tools.", "textElements": []},
                    ]})
                    deadline = time.monotonic() + 60
                    while time.monotonic() < deadline:
                        event = server.receive(max(0.1, deadline - time.monotonic()))
                        if event.get("method") == "turn/completed":
                            break
                except RuntimeError as error:
                    invocation_error = str(error)
                events = server.events
            finally:
                server.close()
        # A successful turn/start or provider error alone is NOT invocation
        # proof. Require the actual native outgoing model input to contain the
        # complete selected skill body, not merely its skills-list description.
        skill_text = original_skill.decode("utf-8").replace("\r\n", "\n")
        skill_body = skill_text.split("---", 2)[-1].strip() if skill_text.startswith("---") else skill_text.strip()
        expanded = any(skill_body in text.replace("\r\n", "\n") for request in requests for text in strings(request.get("input", [])))
        if not expanded:
            detail = invocation_error or json.dumps([event for event in events if event.get("method") in ("error", "turn/completed")])
            raise RuntimeError("Native CE discovery passed, but explicit native skill expansion was not proved. " + detail)
        print("Verified: explicit native Skill input expanded the pinned CE skill body into the outgoing model request")
        print("Model completion NOT exercised: the localhost capture-only endpoint deliberately returned HTTP 400; no credentials or OAuth were used.")


if __name__ == "__main__":
    main()
