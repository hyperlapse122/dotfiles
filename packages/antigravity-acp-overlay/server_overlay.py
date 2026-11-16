import functools
import os

from . import proxy_agent_config, server, settings

settings._TOP_LEVEL_KEYS += ("allowNonWorkspaceAccess",)


def _enabled():
    path = os.environ.get("ANTIGRAVITY_ACP_SHARED_SETTINGS_FILE") or settings.settings_path()
    try:
        with open(path, encoding="utf-8") as handle:
            value = settings.hjson.load(handle)
    except (OSError, ValueError):
        return False
    return isinstance(value, dict) and value.get("allowNonWorkspaceAccess") is True


_scope_policy = server._view_file_scope_policy


def view_file_scope_policy(allowed_dirs):
    if _enabled():
        return server.policy.allow(server.sdk_types_module.BuiltinTools.VIEW_FILE.value)
    return _scope_policy(allowed_dirs)


def _client_factory(factory):
    @functools.wraps(factory)
    def create(*args, **kwargs):
        kwargs["defer_scope"] = kwargs.get("defer_scope", False) or _enabled()
        return factory(*args, **kwargs)

    return create


_build_harness_config = proxy_agent_config.LocalConnectionStrategy._build_harness_config


def build_harness_config(self):
    config = _build_harness_config(self)
    if _enabled():
        config.policy_config.workspace_containment = (
            proxy_agent_config.localharness_pb2.PolicyConfig.WORKSPACE_CONTAINMENT_DISABLED
        )
    return config


# Keep safe_defaults and the ACP permission handler as the approval authority.
# Enterprise deny/ask policies remain in the server's policy list.
server._view_file_scope_policy = view_file_scope_policy
for _name in ("make_client_view_file", "make_client_create_file", "make_client_edit_file"):
    setattr(server.tools, _name, _client_factory(getattr(server.tools, _name)))
proxy_agent_config.LocalConnectionStrategy._build_harness_config = build_harness_config
