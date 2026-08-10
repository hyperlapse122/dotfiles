---
description: Avoid unnecessary hash comments; write self-explanatory code instead.
condition:
  - '(?im)(?:^|(?<=\s))#(?!\!)(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$)))\s*'
scope:
  - 'tool:edit(*.{py,rb,sh,bash,yaml,yml,toml,hcl,tf,ex,exs,php})'
  - 'tool:edit(**/Dockerfile)'
  - 'tool:write(*.{py,rb,sh,bash,yaml,yml,toml,hcl,tf,ex,exs,php})'
  - 'tool:write(**/Dockerfile)'
interruptMode: never
---

Remove unnecessary `#` comments from every file you touched this turn.

## Why

Names, structure, and direct configuration express intent better than comments that repeat nearby code. Removing redundant comments keeps files easier to scan and maintain.

## Examples

Avoid:

```py
# Return the active user
return active_user
```

Prefer:

```py
return active_user
```

## Exceptions

Keep shebangs, required BDD steps, linter and compiler directives, Go toolchain directives, and URLs. Keep comments only when they explain non-obvious constraints or external facts that code cannot express.
