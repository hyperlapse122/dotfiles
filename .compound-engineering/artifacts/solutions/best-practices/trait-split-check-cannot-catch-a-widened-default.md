---
title: "A check that splits outputs by the trait it guards cannot catch a widened default"
date: "2026-10-07"
category: best-practices
module: NixOS flake checks (trait-defaulted services)
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A repository check guards a trait whose profile default is computed from other options, such as `mkDefault (config.my.podman.enable && !config.my.bootstrap)`"
  - "The check sorts configurations into enabled and disabled with `configurations.withTrait`, which reads the same trait it is meant to guard"
  - "Mutation-testing such a check by dropping one clause of the computed default"
  - "Hosts are allowed to override the trait, so the check must accept a per-host opt-out"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - traits
  - bootstrap
---

# A check that splits outputs by the trait it guards cannot catch a widened default

## Context

The `minikube.enable` default in `modules/nixos/profile.nix` turns the rootless minikube cluster on with a computed default:

```nix
minikube.enable = lib.mkDefault (config.my.podman.enable && !config.my.bootstrap);
```

`tests/minikube-autostart.nix` guards it. The first version split the configurations with `configurations.withTrait "my.minikube.enable"` (`tests/lib/configurations.nix:137`): units must exist on `enabled`, and must be absent on `disabled`. `withTrait` computes both lists from the trait's own value, and falls back to forced-off production outputs only when `disabled` is empty (`tests/lib/configurations.nix:144`).

Mutation testing in a scratch copy changed the default to `lib.mkDefault config.my.podman.enable`, dropping the bootstrap clause. The check stayed green. With the mutation, the bootstrap outputs ran the cluster, so `withTrait` put them in `enabled`, and they passed the positive assertions. Nothing in the check said where a bootstrap output belonged.

The second version stated the expected split on its own terms: every production output with Podman must run the cluster, and every bootstrap output must not. That killed the mutation. The cross-model adversarial review then showed it also rejected a legitimate configuration: a host that sets `my.minikube.enable = false` while keeping Podman got a correct output with no cluster, and the check demanded the unit anyway. The trait is a `mkDefault`, so a per-host opt-out is part of its contract.

## Guidance

Judge each output by its own trait, and pin each input clause of the computed default with an explicit negative case that the trait split cannot reclassify:

```nix
minikube = configurations.withTrait "my.minikube.enable" (config: config.my.minikube.enable);
forcedOff =
  option: map (configurations.withTraitForcedOff option) (lib.take 1 configurations.production);

# Positive side: whatever actually enables the trait.
assertEnabled minikube.enabled
# Negative side: what actually disables it, plus every input clause pinned.
assertDisabled (
  lib.filter (entry: !entry.bootstrap) minikube.disabled
  ++ configurations.bootstraps            # the !bootstrap clause
  ++ forcedOff "my.minikube.enable"       # the trait itself
  ++ forcedOff "my.podman.enable"         # the podman clause
)
```

The shape is in `tests/minikube-autostart.nix:189-195`. `withTraitForcedOff` and `linuxFixtures` are exported from `tests/lib/configurations.nix` for this.

- Listing `configurations.bootstraps` explicitly is what catches the dropped bootstrap clause: those outputs are asserted off whatever the trait says.
- Re-evaluating a production output with the parent trait forced off (`my.podman.enable`) is what catches a default that stops following it.
- `minikube.guard` still fails the build when no production output enables the trait, so a default that narrows to `false` fails on the positive side.
- A host that opts out lands in `minikube.disabled` and is asserted off, which is correct, so the override stays legal.

## Why This Matters

`withTrait` is the right helper for a hardware trait a host sets explicitly, because there the trait is the input. For a computed default, the trait is the output under test. Deriving the expected split from it makes the check self-referential: any change to the default moves outputs between the buckets, and each bucket's assertions still hold. Mutation rounds then report the check sound when it is decorative, as in [mutation-testing-reveals-decorative-nix-check-assertions.md](mutation-testing-reveals-decorative-nix-check-assertions.md).

The opposite fix, hard-coding the expected split from the inputs, overcorrects. It turns a `mkDefault` into a rule no host may override, and the first legitimate opt-out turns the check red. Both rounds of this work hit one of the two failures; the shape above avoids both.

## When to Apply

- Any check over a trait whose profile default is a boolean expression of other options or of `my.bootstrap`, such as the `tailscale` and `protonVpn` defaults in `modules/nixos/profile.nix`.
- When a mutation that drops or flips one clause of a default leaves the check green: look for an expected split read from the trait being guarded.
- Not needed for traits a host sets directly with no computed default, such as `my.t3.desktop.enable` (the removed `my.laptop.enable` and `my.nuphyGem80.enable` were others); there `withTrait` alone is the right split.

## Examples

Mutation results recorded while building `tests/minikube-autostart.nix`, run from a scratch copy per [copied-git-worktree-writes-the-real-index.md](copied-git-worktree-writes-the-real-index.md):

| Check shape | Default drops `!bootstrap` | Default ignores Podman | Host sets `my.minikube.enable = false` |
| --- | --- | --- | --- |
| `withTrait` split only | passes (missed) | caught | passes (correct) |
| Split stated from inputs | caught | caught | fails (wrong) |
| Actual split plus pinned clauses | caught | caught | passes (correct) |

Related: [compound-condition-clause-assertions-miss-connective-mutations.md](compound-condition-clause-assertions-miss-connective-mutations.md) pins each clause of a condition the code tests; this learning pins each clause of a default the check reads. [converged-fixture-state-defeats-nix-check-mutation-testing.md](converged-fixture-state-defeats-nix-check-mutation-testing.md) is the fixture-side version of the same failure: the check's inputs cannot tell the correct implementation from the bug.
