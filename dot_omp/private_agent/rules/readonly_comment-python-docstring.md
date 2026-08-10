---
description: Avoid unnecessary Python docstrings; write self-explanatory code instead.
condition:
  - '(?im)^[ \t]*(?:["]{3}|['']{3})(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$)))\s*'
scope:
  - 'tool:edit(*.py)'
  - 'tool:write(*.py)'
interruptMode: never
---

Remove unnecessary Python docstrings from every file you touched this turn.

## Why

A module, class, or function should communicate ordinary behavior through its name, signature, types, and structure. Redundant docstrings drift and duplicate information readers can get directly from the code.

## Examples

Avoid:

```py
def retry_count(attempts: list[Attempt]) -> int:
    """Return the retry count."""
    return len(attempts)
```

Prefer:

```py
def retry_count(attempts: list[Attempt]) -> int:
    return len(attempts)
```

## Exceptions

Keep required BDD steps and linter or compiler directives when they are the leading text of a bare triple-quoted statement. Keep comments only when they explain non-obvious constraints or external facts that code cannot express.
