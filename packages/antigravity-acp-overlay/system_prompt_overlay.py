"""Add the shared agent instructions to the client's system prompt.

The repack tool adds this module to the runtime archive beside system_prompt
and appends an import of it to system_prompt, which runs it after the shipped
function exists. Callers reach the function through system_prompt, so the
rebinding below takes effect.
"""

import glob
import logging
import os

from . import system_prompt

# The frontmatter scripts/agent-instructions writes on each rule file.
FRONTMATTER = "---\ntrigger: always_on\n---\n\n"

_shipped = system_prompt.extract_system_prompt


def _rules():
    directory = os.environ.get("ANTIGRAVITY_ACP_RULES_DIR")
    if not directory:
        return ""
    texts = []
    for path in sorted(glob.glob(os.path.join(glob.escape(directory), "nix-config-*.md"))):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        texts.append(text.removeprefix(FRONTMATTER))
    if not texts:
        logging.warning("No nix-config-*.md rule files in %s; sending no shared instructions", directory)
    return "".join(texts)


def extract_system_prompt(kwargs):
    append = _shipped(kwargs)
    rules = _rules()
    if not rules:
        return append
    return rules.rstrip("\n") + "\n\n" + append if append else rules


system_prompt.extract_system_prompt = extract_system_prompt
