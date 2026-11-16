"""Disable the built-in start_subagent tool in every session.

The repack tool adds this module to the runtime archive beside tool_filter and
appends an import of it to tool_filter. The server resolves each session's
disabled built-ins through ToolFilterConfig.resolve_disabled_builtins, whatever
filter the client sent or the session restored, so adding start_subagent to its
result turns off subagents, and with them the browser subagent, everywhere.
Delegation goes through the client instead, such as T3 Code's delegate_task.
The client's filter itself is stored unchanged.
"""

from . import tool_filter

_shipped = tool_filter.ToolFilterConfig.resolve_disabled_builtins


def resolve_disabled_builtins(self):
    return set(_shipped(self)) | {tool_filter.sdk_types_module.BuiltinTools.START_SUBAGENT}


tool_filter.ToolFilterConfig.resolve_disabled_builtins = resolve_disabled_builtins
