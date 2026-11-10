---
title: "Mutation testing reveals decorative assertions in a Nix flake check"
date: 2026-09-21
category: best-practices
module: "NixOS flake checks (mutation-testing practice)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Writing or reviewing a repo check that asserts properties of generated output"
  - "A check has run green since it was written and its guard status has never been verified by deliberately breaking what it claims to protect"
  - "A check mixes text assertions with a domain validator and the split of responsibility between them has not been established"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - set-e
  - shell-negation
  - ini-parsing
  - keyd
---

# Mutation testing reveals decorative assertions in a Nix flake check

## Context

`tests/keyd-remap.nix`, registered as the `keyd-remap` check in `flake.nix`, asserted what `modules/nixos/hardware/keyd.nix` generated: a keyd configuration remapping Caps Lock to the Hangul key, keeping real Caps Lock on Ctrl+Caps Lock, scoping the remap to the internal keyboard, and a libinput quirk. It passed the first time it ran and was treated as a regression guard from that moment.

The ThinkPad host, the keyd module, and this check were removed in e857618, so the paths, option names, and commands below are historical. The lessons do not depend on keyd. `tests/check-workflow-docs-skip.sh` is a live check that writes its negative assertions in the explicit `if`/`exit` form this doc recommends.

Mutation testing showed two of its assertions could not fail. The check was green partly for reasons unrelated to the module being correct.

This repository requires a check for each new capability, so the failure mode generalises past this one file: nothing about a first green run distinguishes a live assertion from a decorative one.

## The practice

**Mutation-test a check before believing it.** Break the thing each assertion claims to protect, confirm the check fails, restore. For a Nix flake check each round is one substitution plus one build:

```sh
# 1. baseline: the unmutated tree must pass
nix build --no-link .#checks.x86_64-linux.keyd-remap

# 2. break what an assertion claims to protect
perl -0777 -pi -e 's|// lib\.optionalAttrs cfg\.copilotKey \{|// lib.optionalAttrs true {|' modules/nixos/keyd.nix

# 3. the check MUST now fail; if it passes, that assertion is decorative
nix build --no-link .#checks.x86_64-linux.keyd-remap

# 4. restore
git checkout -- modules/nixos/keyd.nix
```

Repeat once per assertion class, not once per assertion.

| Mutation | What it breaks | Must be caught by |
| --- | --- | --- |
| Force the Copilot binding on for the default host | Option-gated output | the `f23` branch |
| Add `*` to the default id list | Keyboard scoping | the wildcard branch |
| Transpose `control.capslock` and `main.capslock` | Section semantics | the sectioned greps |
| Misspell a key name | File validity | `keyd check` |
| Stop the libinput quirk matching keyd | Device classification | the quirk greps |

## What the mutations found

### A negated command asserts nothing under `set -e`

Two assertions were written as `! grep -Fxq ... "$file"`. POSIX exempts a command whose exit status is inverted by `!` from `set -e`, so a Nix builder never fails on one. Both lines were syntactically assertions and semantically comments.

The mutation that forced the optional Copilot binding into the default host's file passed the whole check. A second mutation, widening the id list, *appeared* caught — but only because a positive assertion about the same id list failed. The negative assertion was still dead, and a mutation suite that stopped at "the check went red" would have recorded a false pass.

Write the negation as a branch that exits, and print why:

```sh
if grep -q "f23" "$default"; then
  echo "Copilot binding leaked into the default host configuration" >&2
  exit 1
fi
```

### Whole-line greps are section-blind, and a domain parser does not cover that

The behavioural assertions were whole-file, whole-line greps — `grep -Fxq "capslock=hangeul"` and `grep -Fxq "capslock=capslock"` — with `keyd check` afterwards as a parse gate.

In a keyd configuration the section an entry lives in *is* the meaning of the entry. Transposing the two settings entries yields a file where Caps Lock alone toggles capitalisation and Ctrl+Caps Lock switches input method: the inverse of the intent, not a near miss. Both greps still matched, because both lines still existed somewhere in the file. `keyd check` also passed — it validates key names and syntax, never which section a mapping belongs to.

Slice the section before grepping, so a line in the wrong section fails:

```sh
section() {
  awk -v want="[$1]" '$0 == want { inside = 1; next } /^\[/ { inside = 0 } inside' "$2"
}

section main "$conf" | grep -Fxq "capslock=hangeul"
section control "$conf" | grep -Fxq "capslock=capslock"
```

## Keep the parser, and establish what it covers

`keyd check` is worth keeping. A separate mutation introducing a genuinely invalid key name passed every grep and was caught only there, exiting 255 with `invalid key or action`. A domain validator answers "is this well formed", never "is this what you meant". Explicit assertions answer the second. Neither covers the other's blind spot by accident, and mutation is how you learn where the line actually falls rather than where you assumed it did.

## How to apply

Mutate a check when any of these hold:

- It has only ever been observed green.
- It asserts on generated text rather than behaviour — greps, snapshot comparisons, schema-shape checks. Text assertions fail in the direction of passing.
- It contains a negative assertion. In shell, never `! cmd`; always an explicit `if ... then echo >&2; exit 1; fi`.
- A domain validator is doing part of the work.
- Re-running it is cheap. Here each round is one `nix build --no-link`, with no VM and no hardware.

Two further habits came out of the same pass. Put `set -x` at the top of a builder script whose assertions are quiet by design, so the failing assertion is the last traced line in `nix log`; the default console output truncates, but `nix log <drv>` carries it. And run the invariant assertions over every generated fixture, not only the default one, or an option-specific fixture can drift while the check stays green.

## See also

- [SOPS service umask blocks user secrets](../integration-issues/sops-service-umask-blocks-user-secrets.md) — the same discipline reached a different way. There, a check inspected final ownership and mode and missed a masked directory-traversal bit; the gap surfaced only by exercising a real unprivileged consumer. Here the assertions were structurally incapable of failing. Both are cases of a passing check not proving the behaviour it claims to guard.

## Out of scope for this check

Whether generated configuration reaches the real device or service stays a hardware check (see `CONCEPTS.md` and `AGENTS.md`). For keyd, that was whether it grabbed the internal keyboard and whether the emitted keysym reached the input method. A build-time check on generated configuration cannot reach either.
