import asyncio
import contextlib
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace

from . import server


class Client:
    def __init__(self):
        self.approve = False
        self.requests = []

    async def session_update(self, **kwargs):
        pass

    async def request_permission(self, **kwargs):
        self.requests.append(kwargs)
        outcome = (
            server.schema.AllowedOutcome(outcome="selected", option_id="allow")
            if self.approve else object()
        )
        return SimpleNamespace(outcome=outcome)

    async def write_text_file(self, *, path, content, session_id):
        Path(path).write_text(content)


async def check(directory):
    workspace = directory / "workspace"
    workspace.mkdir()
    external = directory / "Downloads.txt"
    external.write_text("original")
    settings = directory / "settings.json"
    settings.write_text('{"allowNonWorkspaceAccess": true}')
    os.environ["ANTIGRAVITY_ACP_SHARED_SETTINGS_FILE"] = str(settings)
    os.environ["GEMINI_HOME"] = str(directory / "profile")
    adapter = server.AgyAdapter()
    client = Client()
    adapter.on_connect(client)
    adapter._client_fs_capabilities = SimpleNamespace(write_text_file=True)
    adapter._auth_state = server.AuthState(
        method_id=server.AUTH_METHOD_API_KEY, api_key="fake-test-key"
    )
    session_id = "0123456789abcdef0123456789abcdef"
    adapter._sessions[session_id] = server.SessionInfo(
        agent=None, stack=contextlib.AsyncExitStack(), cwd=str(workspace),
        gemini_home=os.environ["GEMINI_HOME"],
    )
    config, _ = await adapter._create_agent_config(
        cwd=str(workspace), session_id=session_id,
        gemini_home=os.environ["GEMINI_HOME"],
        model_id=server.model_selection.get_default_model_id(),
    )
    edit = next(tool for tool in config.tools if tool.__name__ == "client_edit_file")
    hook = server.policy.enforce(config.policies)
    for mode, approve, expected_prompts, expected_allowed in (
        ("default", False, 1, False),
        ("default", True, 1, True),
        ("auto_edit", False, 0, True),
        ("yolo", False, 0, True),
    ):
        external.write_text("original")
        adapter._sessions[session_id].mode_id = mode
        client.approve = approve
        client.requests.clear()
        call = server.sdk_types_module.ToolCall(
            id=f"edit-{mode}-{approve}", name="client_edit_file",
            args={"target_file": str(external), "code_content": "changed"},
        )
        result = await hook.run(None, call)
        assert result.allow is expected_allowed, (mode, approve, result)
        assert len(client.requests) == expected_prompts, (mode, client.requests)
        if client.requests:
            assert client.requests[0]["tool_call"].raw_input == call.args
        if result.allow:
            await edit(**call.args, ctx=SimpleNamespace(conversation_id=session_id))
        assert external.read_text() == ("changed" if expected_allowed else "original")


with tempfile.TemporaryDirectory() as temporary:
    asyncio.run(check(Path(temporary)))
print("Packaged ACP external-edit approval check passed", flush=True)
raise SystemExit(0)
