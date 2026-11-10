---
title: "Removing a host can empty one side of a check that partitions hosts, and only a two-sided guard notices"
date: "2026-10-08"
category: best-practices
module: NixOS flake checks (host-partitioned assertions)
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A host is removed from or added to `hosts/`, so `self.nixosConfigurations` changes shape"
  - "A check splits configurations into two groups by a per-host value that is not a `withTrait` trait, such as a GPU driver or a list option like `my.printing.queues`"
  - "A check guards only one side of such a split against covering zero configurations"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - fleet-shape
  - extend-modules
  - vacuous-pass
---

# Removing a host can empty one side of a check that partitions hosts, and only a two-sided guard notices

## Context

Removing the ThinkPad X1 Carbon Gen 11 left MS-7D91 as the only NixOS host. The checks build their configuration list from `self.nixosConfigurations`, so every check that sorted hosts into two groups lost whatever the ThinkPad alone had supplied. Two checks were found affected, and they failed in opposite ways.

`tests/boot-splash.nix` sorts production configurations into "drives the GPU with NVIDIA" and "does not". The ThinkPad was the only Intel host. The check already failed when every production configuration used NVIDIA (`tests/boot-splash.nix:308`), so `nix flake check` went red and the gap was found at once.

`tests/printing.nix` sorts configurations into "declares printer queues" and "does not" (`tests/printing.nix:57`). The ThinkPad was the only production host without a queue, and MS-7D91 sets `my.printing.queues = [ "office" ]` (`hosts/MS-7D91/default.nix:10`). The check guarded only the queued side. After the removal, its absence assertion ("no `ensure-printers.service` without a queue") covered only `MS-7D91-bootstrap`, and `nix flake check` stayed green. The plan for the removal had told the implementer to look for exactly this and to fix it in "any other check `nix flake check` shows". That instruction trusted the check run to surface every case, and here it surfaced nothing. The cross-model adversarial code review found it. An in-memory mutation gated the module on `!config.my.bootstrap` instead of `queues != [ ]` (`modules/nixos/services/printing.nix:83`), and, per that review's report, the printing check's derivation came out byte-identical.

## Guidance

When a host is removed or added, read every check that partitions configurations, not only those `nix flake check` fails. A trait split through `configurations.withTrait` is already safe: it falls back to production configurations re-evaluated with the trait forced off when no configuration leaves it off (`tests/lib/configurations.nix:144`). Any other split is not, whether by a hardware option or a list option, or done by hand with `lib.filter`.

For each such split, keep both sides covered with the `withTraitForcedOff` shape (`tests/lib/configurations.nix:72`). When real production configurations leave one side empty, append production configurations re-evaluated with `extendModules` so they take that side. Then guard the combined list, so the check fails loudly if the re-evaluation stops taking effect:

```nix
withoutQueues =
  entry:
  configurations.entryOf "${entry.name} with no printer queues" (
    self.nixosConfigurations.${entry.name}.extendModules {
      modules = [ { my.printing.queues = lib.mkForce [ ]; } ];
    }
  );

unqueued =
  lib.filter (entry: !declaresQueues entry) configurations.entries
  ++ lib.optionals (lib.all declaresQueues configurations.production) (
    map withoutQueues configurations.production
  );

unqueuedGuard = lib.optionalString (!lib.any (entry: !entry.bootstrap && !declaresQueues entry) unqueued) ''
  echo 'tests/printing.nix: ... the absence branch would cover no production configuration' >&2
  exit 1
'';
```

The same shape drove the non-NVIDIA branch of `tests/boot-splash.nix` (`withIntelDriver`) until the NVIDIA module was removed with the bare-metal MS-7D91 host. That second removal, which left the VMware guest `MS-7D91-VM` as the only NixOS host, emptied the other side: no production host declared a printer queue or ran resolved beside printing. `tests/printing.nix` now appends `withQueue` and `withResolved` variants the same way, and the queue variant must name a label that exists in `secrets/printers.yaml`, because sops-nix validates every secret it reads against the file's keys at build time.

Mutation-test each variant twice. First break the module so the guarded side would misbehave: the variant must turn the check red. Then disable the variant: the guard must fire. When this fix was made, both printing mutations failed for the expected reasons ("MS-7D91 with no printer queues: no queue is declared for this configuration but ensure-printers.service exists", and the guard message), and so did both boot-splash mutations.

## Why This Matters

A partition check is only as strong as its thinnest side. When the fleet shrinks, a side can go from one configuration to zero without any file in `tests/` changing. A one-sided guard then lets the check pass while asserting nothing about that side, as in [mutation-testing-reveals-decorative-nix-check-assertions.md](mutation-testing-reveals-decorative-nix-check-assertions.md). Bootstrap outputs make this easy to miss. They usually sit on the "off" side of every split, so the side never empties completely and its assertions still run. They just no longer run on any production configuration, which is where a regression would land.

## When to Apply

- Before merging any change that adds or removes a directory under `hosts/`, including fixture hosts under `tests/fixtures/hosts/` for checks that read those.
- When writing a new check that sorts configurations by any value. Add the variant and both guards from the start, not when the fleet happens to shrink.
- Not needed for splits made with `configurations.withTrait`. Its forced-on and forced-off fallbacks and `guard` already cover both sides, though [trait-split-check-cannot-catch-a-widened-default.md](trait-split-check-cannot-catch-a-widened-default.md) still applies when the trait has a computed default.

## Examples

How the two affected checks behaved once MS-7D91 was the only NixOS host:

| Check | Split by | Guard before | Result after host removal | Fix |
| --- | --- | --- | --- | --- |
| `boot-splash` | NVIDIA driver with modesetting | both sides | red in `nix flake check` | `withIntelDriver` variant |
| `printing` | `my.printing.queues` non-empty | queued side only | green, absence side covered only bootstrap | `withoutQueues` variant plus `unqueuedGuard` |

Related: [converged-fixture-state-defeats-nix-check-mutation-testing.md](converged-fixture-state-defeats-nix-check-mutation-testing.md) is the fixture-side form of the same failure, where the check's inputs cannot tell the correct implementation from the bug.
