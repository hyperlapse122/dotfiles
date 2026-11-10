---
title: "A nullable option reaches a shell comparison as an empty word, and the guard passes"
date: 2026-09-22
category: best-practices
module: "NixOS flake checks (generation cleanup retention floor)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check interpolates an option value into a shell comparison, such as if [ \"$n\" -lt ${value} ]"
  - "That option's type admits a value the comparison cannot take -- types.nullOr, an empty list, an empty string"
  - "Mutation-testing a check whose operand does vary, to confirm every value the type admits still leaves the assertion able to go red"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - nullor
  - shell-test-builtin
  - fail-open
  - decorative-assertions
---

# A nullable option reaches a shell comparison as an empty word, and the guard passes

## Context

`tests/nix-cleanup.nix` guards one invariant: the number of generations the weekly cleanup keeps must stay at or above the number of entries the boot menu offers. Below that floor, the menu names generations the collector already removed, which is the rollback path `docs/recovery.md` sends a user to when the system will not boot.

The assertion reads the retention count out of the built start script and compares it against the boot loader's limit:

```nix
limit = esc (bootLimit host.config);
...
elif [ "$keep" -lt ${limit} ]; then
  echo "retention count $keep is below the boot loader configurationLimit ${limit}; ..." >&2
  failed=1
fi
```

The operand is not a constant: `modules/nixos/system/boot.nix` set `boot.lanzaboote.configurationLimit` at the time (it now sets `boot.loader.systemd-boot.configurationLimit`, since NixOS hosts no longer use Lanzaboote), and mutating it to `15` correctly turned the check red. The assertion looked live, and by the repository's existing tests for liveness it was.

It still passed in the one case the invariant exists for.

## Guidance

**Enumerate the values the option's type admits, not the value it holds.** For each one that the comparison cannot take, add a Nix-level branch that fails, rather than letting it reach the shell.

`boot.loader.systemd-boot.configurationLimit` is `types.nullOr types.int`, as Lanzaboote's `configurationLimit` was, with `default = null`, documented in nixpkgs as "`null` means no limit i.e. all generations that have not been garbage collected yet". An unbounded menu is precisely the state a finite retention count cannot cover — and it is the type's default.

With the limit null, the emitted builder line is:

```sh
elif [ "$keep" -lt '' ]; then
```

`toString null` is the empty string and `lib.escapeShellArg` renders it as the two-character literal `''`. `test` answers an empty numeric operand with `integer expression expected` on stderr and exit status 2 — an **error**, not a false. The `elif` branch is therefore not taken, `failed` is never set, and the builder reaches `touch $out`. The check is green while the property is false.

Two details keep the failure quiet. The builder sets `set -x` but not `set -e`, and even under `set -e` a condition in an `if`/`elif` is exempt. And the sibling branch already guarded the *other* empty operand (`if [ -z "$keep" ]`), which makes the missing guard on the limit side easy to read past.

The fix keeps the file's no-eval-abort style by branching in Nix rather than in the shell:

```nix
limitValue = bootLimit host.config;
limit = esc limitValue;

limitUnbounded = lib.optionalString (limitValue == null) (
  fail "the boot loader configurationLimit is null, so the boot menu offers every surviving generation and no finite retention count can cover it"
);
```

and emitting the comparison only when the limit is a number, so no shell error is produced at all:

```nix
${lib.optionalString (limitValue != null) ''
  if [ -n "$keep" ] && [ "$keep" -lt ${limit} ]; then
    ...
  fi
''}
```

## Why This Matters

This repository already carries five learnings about checks that do not guard what they claim, and none of them catches this one. The distinguishing question each of them asks comes out "fine" here:

- [Decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) — *can the assertion's shell fail?* Yes: an explicit `elif` with `failed=1`, not a `! cmd` that `set -e` exempts.
- [An unconditionally set option](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) — *can any mutation change the operand?* Yes: `boot.nix` is under test and a limit of `15` turns it red.
- [Mutations that only break evaluation](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — *does the mutation reach the builder?* Yes: evaluation succeeds and the builder runs.
- [Option value versus materialized output](nix-check-reads-option-value-not-materialized-output.md) — *is the assertion reading a proxy?* No: the retention count is read out of the built start script.
- [Converged fixture state](converged-fixture-state-defeats-nix-check-mutation-testing.md) — *can the fixture tell the bug from the fix?* There is no fixture.

The question none of them asks is **whether every value the operand's type admits still leaves the assertion able to go red**. An operand that varies across the values a reviewer thinks to try is not the same as an operand that is well-formed for every value its type allows. `nullOr` is the common shape, because a null default that means "unbounded" is exactly the state a bound is protecting against — so the type's default value and the assertion's blind spot are the same value.

The shell's treatment of an empty numeric operand is what converts the gap into a pass rather than an error: `test` reports the problem on stderr and returns 2, and an untaken branch is indistinguishable from a satisfied condition.

## When to Apply

- Any check that interpolates an option value into `test`, `[`, `[[`, `case`, or arithmetic. Read the option's `type` in nixpkgs, not just its current value.
- Any option declared `nullOr`, `listOf`, or `str` whose documented empty or null value means "no limit", "all", "disabled", or "unset". Those are the values a bound exists to catch.
- After reading the generated `buildCommand` out of the `.drv`. That read shows the operand that is there today; it says nothing about the operands the type still allows, so it does not substitute for this check.

## Examples

The null-limit round, which passed before the fix and fails after it:

```sh
# mutate: an unbounded boot menu
sed -i 's/boot.loader.systemd-boot.configurationLimit = 5;/boot.loader.systemd-boot.configurationLimit = lib.mkForce null;/' modules/nixos/system/boot.nix
nix build --no-link .#checks.x86_64-linux.nix-cleanup
```

| Round | Mutation | Before the fix | After the fix |
| --- | --- | --- | --- |
| Retention count `--keep 3` | a floor below the limit | red: `retention count 3 is below the boot loader configurationLimit 5` | same |
| `configurationLimit = 15` | the limit raised past the floor | red, from the other side | same |
| `configurationLimit = null` | the limit removed entirely | **green** — `[ "10" -lt '' ]` errored and the branch was skipped | red, in the builder: `the boot loader configurationLimit is null, so the boot menu offers every surviving generation and no finite retention count can cover it` |

Only the third row fails open. The first two rows hide that: a mutation suite that only moves the limit *within* its integer range scores full marks on an assertion that fails open at the range's edge.

The shell behavior on its own, reproducible without Nix:

```sh
$ keep=10; if [ "$keep" -lt '' ]; then echo TAKEN; else echo SKIPPED; fi
bash: line 1: [: : integer expression expected
SKIPPED
```

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md)
- [An assertion on an unconditionally set option compiles to a constant](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) — the closest sibling, and the one this doc is most often mistaken for. There the operand cannot vary; here it varies and still cannot go red at one of its legal values.
- [A mutation that only breaks Nix evaluation proves nothing about a check](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md)
- [A check that reads an option value instead of the materialized output](nix-check-reads-option-value-not-materialized-output.md)
- [Converged fixture state defeats mutation testing](converged-fixture-state-defeats-nix-check-mutation-testing.md)

## Out of scope

Whether the boot menu's entries on the running machine actually correspond to surviving generations is not a build-time question. Nothing in this repository rewrites `/boot` outside a rebuild, so that correspondence rests on the retention floor holding; confirming boot-menu correspondence on the machine stays a hardware check (see `CONCEPTS.md` and `AGENTS.md`).
