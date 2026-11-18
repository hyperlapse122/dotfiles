import asyncio
import json

from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
from mcp.shared.exceptions import MCPError
import mcp_types as types

from .config import command_config
from .core import DecisionError, error
from .ipc import request
from .schema import tool_input_schema


def tool_result(body, *, failed=False):
    return types.CallToolResult(
        content=[types.TextContent(type='text', text=json.dumps(body, ensure_ascii=False))],
        structuredContent=body if isinstance(body, dict) else None,
        isError=failed,
    )


async def list_tools(_context, _params):
    return types.ListToolsResult(tools=[types.Tool(
        name='judge',
        description=('Submit typed questions about supplied state to the configured Decisions '
                     'backend. Use noul for a probability, choice for named alternatives, '
                     'score for ordered criteria, or box for image coordinates where supported. '
                     'The configured backend may send the supplied data to OpenRouter.'),
        inputSchema=tool_input_schema(),
    )])


async def call_tool(_context, params):
    if params.name != 'judge':
        raise MCPError(types.ErrorData(code=types.INVALID_PARAMS, message='Unknown Decisions tool'))
    try:
        config = command_config()
    except (OSError, ValueError):
        return tool_result(error(400, 'Cannot read Decisions configuration; check its settings and permissions').body,
                           failed=True)

    document = dict(params.arguments or {})
    document.setdefault('model', config.model)
    try:
        return tool_result(await request(config.socket, document, config.timeout))
    except DecisionError as exc:
        return tool_result(exc.body, failed=True)


async def main():
    server = Server('decide', on_list_tools=list_tools, on_call_tool=call_tool)
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == '__main__':
    asyncio.run(main())
