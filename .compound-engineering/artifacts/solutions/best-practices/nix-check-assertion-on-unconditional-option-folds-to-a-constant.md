---
title: "An assertion on an unconditionally set option compiles to a constant and can never fail"
date: 2026-09-22
category: best-practices
module: "NixOS flake checks (yubikey FIDO tooling)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check asserts a NixOS or Home Manager option value by interpolating it into the builder, such as if [ \"${builtins.toJSON value}\" != \"true\" ]"
  - "The option under assertion is also set unconditionally by another module, so nothing in the change under test can alter it"
  - "Replacing an option read with a read of the artifact that option produces, where a disabled service leaves no such attribute"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - eval-time-interpolation
  - decorative-assertions
  - systemd-units
---

# An assertion on an unconditionally set option compiles to a constant and can never fail

## Context

`tests/yubikey-fido.nix` guards the YubiKey inventory tooling. One of its assertions read `services.pcscd.enable`, written in this repository's established boolean idiom:

```nix
if [ "${builtins.toJSON value}" != "true" ]; then
  echo '<host>: services.pcscd.enable is not true' >&2
  exit 1
fi
```

That form follows [the decorative-assertion learning](mutation-testing-reveals-decorative-nix-check-assertions.md) correctly: it is an explicit `if`, not a `! grep` that `set -e` would exempt. It still could not fail.

`builtins.toJSON value` resolves during evaluation, so the value never reaches the builder as a variable. `modules/nixos/system/base.nix` sets `services.pcscd.enable = true` unconditionally, so the interpolation produced the literal string `true`, and the built derivation contained:

```sh
if [ "true" != "true" ]; then
```

The assertion was a comparison of a constant against itself. Nothing in the module under test could reach it.

It survived a five-round mutation suite and four independent document reviewers. Every round changed the module being tested; none could change an option another module sets unconditionally, so every round left that assertion green and the greenness read as success. What exposed it was reading the generated `buildCommand` out of the built `.drv`, not reading the Nix source.

## Why the existing learnings do not catch this

The three sibling learnings each describe a different failure:

- [Decorative assertions](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion's *shell* cannot fail. Here the shell is fine; the operand is a constant.
- [Evaluation-only mutations](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — the mutation never reaches the assertion. Here the mutation reaches it and the assertion runs.
- [Option value versus materialized output](nix-check-reads-option-value-not-materialized-output.md) — the assertion reads a proxy that can come apart from the outcome. That is the closest, and its guard is the right fix, but its examples are options the module under test *does* set. The case here is an option the module under test **cannot** set, which is what makes the assertion constant rather than merely indirect.

The distinguishing question is not "does this assertion read an option?" but **"can any mutation of the code under test change the value this assertion compares?"** When the answer is no, the assertion is documentation written as an `if`.

## The guard

Assert the artifact the option produces, not the option:

```nix
root = host.config.systemd.units."pcscd.socket".unit or null;
```

Reading the rendered unit means a change that sets the option true while a `mkIf` keeps the unit out of the built system now fails.

**That fix reintroduces the evaluation-abort trap, and the mutation round catches it.** When the service is disabled the attribute does not exist, so an unguarded `host.config.systemd.units."pcscd.socket".unit` throws `attribute '"pcscd.socket"' missing` during evaluation. The check never builds, the assertion never runs, and the round proves nothing — exactly what the unguarded-interpolation learning warns about, arriving through an attribute that disappears rather than a `findFirst` that returns null. Resolve it with `or null` and an absent branch that reports inside the builder.

## What was verified

Each round is `nix build --no-link .#checks.x86_64-linux.yubikey-fido`, with the failure's origin read from `nix log` rather than inferred from the exit code.

| Round | Mutation | Before the guard | After the guard |
| --- | --- | --- | --- |
| 1 | remove the module import from the host | green on the pcscd assertion (it is not the module's to set) | same, and correctly so — recorded as expected rather than as a miss |
| 2 | `services.pcscd.enable = false` in `base.nix`, module removed | green — the emitted shell was `[ "true" != "true" ]` regardless | red, in the builder: `the built system declares no pcscd.socket unit at all` |
| 3 | same as 2, with the fix applied but unguarded | — | red **in the evaluator**: `attribute '"pcscd.socket"' missing`, which proves nothing |

Round 3 is the control: it looks like a pass and is not one. Without reading where the failure came from, the unguarded fix would have been recorded as verified.

## How to apply

- For every assertion in a check, name the mutation that would turn it red. If you cannot write one that the code under test can actually perform, the assertion is constant — delete it, or move it to the artifact the option produces.
- Read the generated `buildCommand` out of the built `.drv` at least once per new check. Eval-time interpolation is invisible in the Nix source and obvious in the derivation.
- Treat an option another module sets unconditionally as a precondition, not a guard. Stating it in prose costs nothing and claims nothing; asserting it claims coverage that does not exist.
- When you move an assertion from an option to its artifact, check what happens to that attribute when the feature is off. A disappearing attribute needs `or null`; a null derivation needs `lib.optionalString`. Both failures must land in the builder.
- Collect failures rather than exiting at the first. A check that stops at its first red assertion yields evidence for one assertion per round, so the rest stay unproven no matter how many rounds are run.

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion's shell cannot fail.
- [A mutation that only breaks Nix evaluation proves nothing about a check](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — the mutation never reaches the assertion, which is how the fix here fails if left unguarded.
- [A check that reads an option value passes when the option is disabled or renamed](nix-check-reads-option-value-not-materialized-output.md) — the assertion reads a proxy for the property; this doc is the case where the proxy is also outside the change's reach.
- [Converged fixture state defeats mutation testing](converged-fixture-state-defeats-nix-check-mutation-testing.md) — a green round that could not have gone red for a different reason.

## Out of scope

Whether the smart-card daemon actually runs after activation is not a build-time question; confirming card access on the machine stays a hardware check (see `CONCEPTS.md` and `AGENTS.md`).
