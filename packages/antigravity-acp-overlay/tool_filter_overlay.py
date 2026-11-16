"""Disable the built-in start_subagent tool in every session.

The repack tool adds this module to the runtime archive beside tool_filter and
appends an import of it to tool_filter. The server resolves each session's
disabled built-ins through ToolFilterConfig.resolve_disabled_builtins, whatever
filter the client sent or the session restored, so adding start_subagent to its
result turns off subagents, and with them the browser subagent, everywhere.
"""

from . import tool_filter

_shipped = tool_filter.ToolFilterConfig.resolve_disabled_builtins
# Looked up at import, which runtime startup performs, so a release that renames
# it fails the package's initialize check instead of every session.
_START_SUBAGENT = tool_filter.sdk_types_module.BuiltinTools.START_SUBAGENT


def resolve_disabled_builtins(self):
    return set(_shipped(self)) | {_START_SUBAGENT}


tool_filter.ToolFilterConfig.resolve_disabled_builtins = resolve_disabled_builtins
