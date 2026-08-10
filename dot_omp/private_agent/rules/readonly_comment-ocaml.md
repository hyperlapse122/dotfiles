---
description: Avoid unnecessary OCaml comments.
condition:
  - '(?is)\(\*(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$))).*?\*\)'
scope:
  - 'tool:edit(*.{ml,mli})'
  - 'tool:write(*.{ml,mli})'
interruptMode: never
---

Remove unnecessary OCaml comments from every file you touched this turn.

## Why

Types, module names, and expression structure should explain normal behavior. Redundant comments add noise and become inaccurate as the implementation changes.

## Examples

Avoid:

```ocaml
(* Return the total *)
let total items = List.length items
```

Prefer:

```ocaml
let total items = List.length items
```

## Exceptions

Keep required BDD steps, linter and compiler directives, Go toolchain directives, shebangs, and URLs. Keep comments only when they explain non-obvious constraints or external facts that code cannot express.
