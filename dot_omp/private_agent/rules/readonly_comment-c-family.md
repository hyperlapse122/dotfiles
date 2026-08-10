---
description: Avoid unnecessary C-family comments; write self-explanatory code instead.
condition:
  - '(?im)(?:^|(?<=\s))(?<![:(])//(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$)))\s*'
  - '(?is)/\*(?!\s*(?:@?(?:type:|noqa|pyright:|ruff:|mypy:|pylint:|flake8:|pyre:|pytype:|eslint-disable|eslint-ignore|prettier-ignore|ts-ignore|ts-expect-error|clippy:|allow|deny|warn|forbid|go:|nolint)|(?:given|when&then|when|then|arrange|act|assert)(?:\s|$))).*?\*/'
scope:
  - 'tool:edit(*.{js,jsx,ts,tsx,go,java,kt,scala,c,h,cpp,cc,cxx,hpp,rs,cs,swift,proto,groovy,cue,php,svelte,css})'
  - 'tool:write(*.{js,jsx,ts,tsx,go,java,kt,scala,c,h,cpp,cc,cxx,hpp,rs,cs,swift,proto,groovy,cue,php,svelte,css})'
interruptMode: never
---

Remove unnecessary `//` and `/* ... */` comments from every file you touched this turn.

## Why

Code should show its intent through names, structure, and small focused operations. Comments that restate code become stale and hide the important information.

## Examples

Avoid:

```ts
// Increment the retry count
retries += 1;
```

Prefer:

```ts
retries += 1;
```

## Exceptions

Keep required BDD steps, linter and compiler directives, Go toolchain directives, shebangs, and URLs. Keep comments only when they explain non-obvious constraints or external facts that code cannot express.
