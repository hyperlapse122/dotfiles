"""Point the first user-global skills directory at the plugin skills.

The repack tool adds this module to the runtime archive beside paths and
appends an import of it to paths. Callers reach the function through paths, so
the rebinding below takes effect.
"""

import os

from . import paths

_shipped = paths.global_skills_paths


def global_skills_paths():
    config, *rest = _shipped()
    plugin = os.environ.get("ANTIGRAVITY_ACP_PLUGIN_SKILLS")
    if plugin and os.path.isdir(plugin):
        config = plugin
    return (config, *rest)


paths.global_skills_paths = global_skills_paths
