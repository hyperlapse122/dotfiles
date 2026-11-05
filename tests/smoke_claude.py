"""Prove native Claude settings, instructions, and CE in a disposable home.

The localhost endpoint captures and rejects model requests. No real login or
model completion is used; command discovery and expansion are separate proof.
"""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading

from smoke_personal_apps import REPO, check_version, executable, run, temporary_destination

PLUGIN_ID = "compound-engineering@compound-engineering-plugin"


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

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            body = b'{"type":"error","error":{"type":"invalid_request_error","message":"Intentional capture-only rejection"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
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
        (outside / ".git").mkdir()
        for relative in (".chezmoidata", ".chezmoitemplates", ".chezmoiignore", "private_dot_claude",
                ".chezmoiexternals/personal-apps.toml.tmpl", ".chezmoiexternals/harness-plugins.toml.tmpl",
                ".chezmoiscripts/run_after_26-claude-plugins.sh.tmpl", ".chezmoiscripts/run_after_26-claude-plugins.ps1.tmpl"):
            origin, destination = REPO / "home" / relative, source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if origin.is_dir():
                shutil.copytree(origin, destination)
            else:
                shutil.copy2(origin, destination)
        declarations_path = source / ".chezmoidata/personal-apps.json"
        declarations = json.loads(declarations_path.read_text(encoding="utf-8"))
        declarations["personalApps"] = {"claude": declarations["personalApps"]["claude"]}
        declarations_path.write_text(json.dumps(declarations), encoding="utf-8")
        (source / ".chezmoitemplates/agent-instructions").write_text(
            'claude-smoke-common-instructions\n'
            '{{ if eq .harness "claude" }}claude-smoke-native-instructions{{ end }}\n'
            '{{ if eq .harness "codex" }}claude-smoke-foreign-instructions{{ end }}\n'
            '{{ if eq .harness "omp" }}claude-smoke-foreign-instructions{{ end }}\n', encoding="utf-8")
        config = root / "chezmoi.toml"
        config_text = ""
        if os.name == "nt":
            shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
            config_text = ('[interpreters.ps1]\ncommand = ' + json.dumps(str(shell)) +
                '\nargs = ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]\n')
        config.write_text(config_text, encoding="utf-8")
        env = {key: value for key, value in os.environ.items()
            if not key.upper().startswith(("CLAUDE", "ANTHROPIC_", "AWS_", "AZURE_", "GOOGLE_"))}
        env.update({"HOME": str(home), "USERPROFILE": str(home),
            "APPDATA": str(root / "config"), "LOCALAPPDATA": str(root / "local"),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_CONFIG_DIRS": str(root / "system-config"),
            "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"), "NO_COLOR": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
        command = [chezmoi, "--config", str(config), "--source", str(source), "--destination", str(home),
            "--cache", str(root / "chezmoi-cache"), "--persistent-state", str(root / "chezmoi-state"), "--no-tty"]

        def chez(*arguments):
            return run(command + list(arguments), env=env, cwd=outside)

        target = chez("execute-template", "{{ .chezmoi.os }}-{{ .chezmoi.arch }}")
        if args.expected_target and target != args.expected_target:
            raise RuntimeError(f"Expected {args.expected_target}, got {target}")
        if target not in declarations["personalApps"]["claude"]["targets"]:
            raise RuntimeError(f"No committed Claude binary for {target}")
        global_config = home / ".claude.json"
        global_config.write_text(json.dumps({"ownerScopeFixture": "native-default"}), encoding="utf-8")
        chez("apply", "--force", "--exclude=scripts")
        binary = home / ".local/bin" / ("claude.exe" if os.name == "nt" else "claude")

        def claude(*arguments):
            return run([str(binary), *arguments], env=env, cwd=outside)

        version = claude("--version")
        check_version(version, pins["personalAppLocks"]["claude"]["tag"])
        managed = home / ".local/share/dotfiles/harness-plugins/compound-engineering"
        original_skill = (managed / "skills/ce-plan/SKILL.md").read_bytes()
        settings_path = home / ".claude/settings.json"
        chez("apply", "--force")

        def installed_ce():
            installed = json.loads(claude("plugin", "list", "--json"))
            ce = next(item for item in installed if item["id"] == PLUGIN_ID and item["scope"] == "user")
            if not ce["enabled"] or not Path(ce["readFromFolder"]).samefile(managed):
                raise RuntimeError("Native CE must be enabled and load from the pinned local source")
            return ce

        installed_ce()
        if json.loads(global_config.read_text(encoding="utf-8")).get("ownerScopeFixture") != "native-default":
            raise RuntimeError("Native apply changed unrelated default global state")
        if (home / ".claude/.claude.json").exists():
            raise RuntimeError("Native plugin apply split the default global configuration")
        unrelated = root / "unrelated"
        (unrelated / ".claude-plugin").mkdir(parents=True)
        (unrelated / ".claude-plugin/marketplace.json").write_text(json.dumps({
            "name": "smoke-unrelated", "owner": {"name": "smoke"},
            "plugins": [{"name": "smoke-unrelated", "source": "./"}]}), encoding="utf-8")
        (unrelated / ".claude-plugin/plugin.json").write_text(json.dumps({
            "name": "smoke-unrelated", "version": "1.0.0", "description": "Independent smoke plugin"}), encoding="utf-8")
        claude("plugin", "marketplace", "add", str(unrelated), "--scope", "user", "--json")
        claude("plugin", "install", "smoke-unrelated@smoke-unrelated", "--scope", "user", "--json")
        claude("plugin", "disable", "smoke-unrelated@smoke-unrelated", "--scope", "user", "--json")
        stale = root / "stale-ce"
        stale.mkdir()
        for name in (".claude-plugin", "skills"):
            shutil.copytree(managed / name, stale / name)
        claude("plugin", "marketplace", "add", str(stale), "--scope", "user", "--json")
        claude("plugin", "install", PLUGIN_ID, "--scope", "user", "--json")
        claude("plugin", "disable", PLUGIN_ID, "--scope", "user", "--json")
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        settings.update(language="english", autoMemoryEnabled=True, ownerFixture="keep",
            autoMemoryDirectory=str(home / ".claude/smoke-memory"))
        settings["env"]["DISABLE_AUTOUPDATER"] = "0"
        settings["env"]["OWNER_FIXTURE"] = "keep"
        settings_path.write_text(json.dumps(settings), encoding="utf-8")
        memory = home / ".claude/smoke-memory/MEMORY.md"
        memory.parent.mkdir(parents=True, exist_ok=True)
        memory.write_text("claude-smoke-disabled-memory-marker", encoding="utf-8")
        preserved = memory.read_bytes()
        (managed / "skills/ce-plan/SKILL.md").write_text("managed source drift", encoding="utf-8")
        for _ in range(2):
            chez("apply", "--force")
            installed_ce()
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
        if (settings["language"] != "korean" or settings["autoMemoryEnabled"] is not False
                or settings["env"]["DISABLE_AUTOUPDATER"] != "1"
                or settings["env"]["OWNER_FIXTURE"] != "keep" or settings["ownerFixture"] != "keep"):
            raise RuntimeError("Repeated apply did not reconcile owned preferences and preserve unrelated values")
        if memory.read_bytes() != preserved or (managed / "skills/ce-plan/SKILL.md").read_bytes() != original_skill:
            raise RuntimeError("Repeated apply damaged memory or failed to restore the pinned source")
        other = next(item for item in json.loads(claude("plugin", "list", "--json")) if item["id"] == "smoke-unrelated@smoke-unrelated")
        if other["enabled"] or not Path(other["readFromFolder"]).samefile(unrelated):
            raise RuntimeError("Repeated apply changed the unrelated native plugin")
        print(f"Native {target}: {version}; CE {ce_pin['tag']} ({ce_pin['commit']})")
        print("Verified: native local CE source, stale-source repair, enabled-state convergence, owned preference repair, unrelated plugin/settings and memory preservation")

        with capture_requests() as (endpoint, requests):
            capture_env = {**env, "ANTHROPIC_BASE_URL": endpoint, "ANTHROPIC_API_KEY": "inert-local-capture-key",
                "ANTHROPIC_AUTH_TOKEN": "inert-local-capture-token", "API_TIMEOUT_MS": "15000"}
            invocation = [str(binary), "--print", "/compound-engineering:ce-plan Explain this skill without running tools.",
                "--tools", "", "--max-turns", "1", "--no-session-persistence", "--strict-mcp-config",
                "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "user"]
            # Establish that this fixture is a real native memory source before
            # asserting that the managed preference excludes it.
            subprocess.run(invocation + ["--settings", '{"autoMemoryEnabled":true}'], env=capture_env,
                cwd=outside, capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=90)
            if "claude-smoke-disabled-memory-marker" not in "\n".join(strings(requests)):
                raise RuntimeError("Enabled native automatic-memory characterization did not consume the fixture")
            requests.clear()
            result = subprocess.run(invocation, env=capture_env, cwd=outside,
                capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=90)
        texts = list(strings(requests))
        prompt = "\n".join(texts).replace("\r\n", "\n")
        for marker in ("claude-smoke-common-instructions", "claude-smoke-native-instructions"):
            if marker not in prompt:
                raise RuntimeError("Native outgoing request is missing user instruction " + marker + "\n" + result.stdout + result.stderr)
        if "claude-smoke-foreign-instructions" in prompt or "claude-smoke-disabled-memory-marker" in prompt:
            raise RuntimeError("Native outgoing request includes foreign instructions or disabled memory")
        if "korean" not in prompt.lower():
            raise RuntimeError("Native outgoing request does not reflect the Korean response preference")
        skill_text = original_skill.decode("utf-8").replace("\r\n", "\n")
        skill_body = skill_text.split("---", 2)[-1].strip() if skill_text.startswith("---") else skill_text.strip()
        if skill_body not in prompt:
            raise RuntimeError("Native explicit CE invocation did not expand the pinned skill body\n" + result.stdout + result.stderr)
        print("Verified: native user instructions, Korean preference, disabled automatic memory, and explicit pinned CE skill expansion in the outgoing model request")
        print("Model completion NOT exercised: the localhost capture-only endpoint deliberately returned HTTP 400; no real credentials or OAuth were used.")
        plugin_data = source / ".chezmoidata/harness-plugins.json"
        declared = json.loads(plugin_data.read_text(encoding="utf-8"))
        declared["harnessPlugins"]["compound-engineering"]["claude"]["plugin"] = "dotfiles-missing-native-plugin"
        plugin_data.write_text(json.dumps(declared), encoding="utf-8")
        failed = subprocess.run(command + ["apply", "--force"], env=env, cwd=outside,
            capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=90)
        if failed.returncode == 0:
            raise RuntimeError("Apply swallowed a genuine native plugin installation failure")
        print("Verified: a genuine native plugin installation failure stops apply")


if __name__ == "__main__":
    main()
