---
description: Avoid unnecessary HTML and XML comments.
condition:
  - '(?is)<!\-\-(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$))).*?\-\->'
scope:
  - 'tool:edit(*.{html,htm,svelte})'
  - 'tool:write(*.{html,htm,svelte})'
interruptMode: never
---

Remove unnecessary HTML or XML comments from every file you touched this turn.

## Why

Markup should make its structure and purpose clear through semantic elements and focused component names. Comments that narrate visible markup quickly become stale.

## Examples

Avoid:

```html
<!-- Main page title -->
<h1>Settings</h1>
```

Prefer:

```html
<h1>Settings</h1>
```

## Exceptions

Keep required BDD steps, linter and compiler directives, Go toolchain directives, shebangs, and URLs. Keep comments only when they explain non-obvious constraints or external facts that markup cannot express.
