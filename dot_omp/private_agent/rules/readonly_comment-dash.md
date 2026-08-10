---
description: Avoid unnecessary dash, SQL block, and Elm comments.
condition:
  - '(?im)(?:^|(?<=\s))--(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$)))\s*'
  - '(?is)/\*(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$))).*?\*/'
  - '(?is)\{-(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$))).*?-\}'
scope:
  - 'tool:edit(*.{lua,sql,elm})'
  - 'tool:write(*.{lua,sql,elm})'
interruptMode: never
---

Remove unnecessary comments from every Lua, SQL, or Elm file you touched this turn.

## Why

Code and queries should make routine steps clear without narrative comments. Redundant comments drift as the surrounding statement changes.

## Examples

Avoid:

```sql
-- Select active users
SELECT * FROM users WHERE active;
```

Prefer:

```sql
SELECT * FROM users WHERE active;
```

## Exceptions

Keep required BDD steps, linter and compiler directives, Go toolchain directives, shebangs, and URLs. Keep comments only when they explain non-obvious constraints or external facts that code cannot express.
