---
title: "A check that a systemd unit exists passes when the unit is disabled, because NixOS masks it to /dev/null"
date: 2026-09-26
category: best-practices
module: "NixOS flake checks (systemd unit assertions)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check asserts that a systemd unit is present in the materialized /etc/systemd/system tree with an existence test such as [ -e ... ]"
  - "The unit comes from a package (systemd.packages) or a module, and something could set systemd.services.<name>.enable = false"
  - "Mutation-testing a check that guards a service, where the mutation list has only removed the module or turned the feature option off"
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - systemd-units
  - decorative-assertions
  - masked-unit
---

# A check that a systemd unit exists passes when the unit is disabled, because NixOS masks it to /dev/null

## Context

`tests/thunderbolt.nix` (removed with the ThinkPad host in e857618) guarded the ThinkPad's bolt daemon. Its first version asserted the unit with the repository's `assertPath` helper: `[ -e "${units}/bolt.service" ]`, where `units` is `host.config.environment.etc."systemd/system".source`. That reads the materialized unit tree, which is what [the option-value learning](nix-check-reads-option-value-not-materialized-output.md) asks for, and it passed every mutation in the plan: removing the module, forcing `services.hardware.bolt.enable = lib.mkForce false`, and swapping the package out.

The lesson applies to any unit assertion; `tests/nix-cleanup.nix`, which reads `systemd.units."nh-clean.service".unit`, is a live example.

Code review then tried `systemd.services.bolt.enable = false`, and the check stayed green. bolt could never start on that system.

## Why an existence test cannot see it

NixOS does not drop a disabled unit from the tree. It renders it as a symlink to `/dev/null`, which is how systemd masks a unit. nixpkgs does this (verified at revs `4975466d` and `e94cb152`, and still so at `6510408d`; a path outside this repository) in `nixos/lib/systemd-lib.nix` (lines 90-98): the `unit-<name>-disabled` derivation runs `ln -s /dev/null "$out/$name"`, and the unit-tree builder preserves those links (lines 470-471).

`/dev/null` exists, so `[ -e ]` is true for a masked unit. The existence test only answers whether something stands at that name, and a masked unit always has something there. `[ -f ]` happens to catch this particular case, because it follows the symlink and `/dev/null` is a character device, not a regular file. It still says nothing about what the unit runs, so a unit that was overridden rather than masked would pass it.

The feature-level mutations cannot surface this. `services.hardware.bolt.enable = false` removes the package from `systemd.packages`, so no unit is written at all and the existence test correctly fails. Only disabling the unit itself, while the package still ships it, produces the masked state. The mutation list has to name that case on purpose.

## The guard

Assert something only the real unit carries. For bolt, that is its `ExecStart` line:

```nix
if units == null then
  fail "${hostName}: the built system declares no /etc/systemd/system tree"
else
  ''
    if ! grep -q '^ExecStart=.*/libexec/boltd$' ${esc "${units}/bolt.service"}; then
      ${fail "${hostName}: the materialised bolt.service is missing, masked, or does not run boltd"}
    fi
  ''
```

`/dev/null` reads as empty, so the grep fails on a masked unit. It fails on a missing file too, since `grep` exits non-zero when it cannot open its input, and the `if !` form keeps that failure inside the builder rather than tripping `set -e`. The `units == null` branch keeps an absent `/etc` entry a builder failure too, per [the unguarded-interpolation learning](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md).

## What was verified

Each round is `nix build --no-link .#checks.x86_64-linux.thunderbolt`.

| Round | Mutation | `[ -e ]` assertion | `ExecStart` assertion |
| --- | --- | --- | --- |
| 1 | module import removed | red | red |
| 2 | `services.hardware.bolt.enable = lib.mkForce false` | red | red |
| 3 | `systemd.services.bolt.enable = false`, bolt still enabled | **green** | red, only the unit assertion, on both configurations (historical: the ThinkPad configurations) |

Round 3 is the only one that tells the two assertions apart, and it is not a feature toggle a reviewer reaches for first.

## How to apply

- To guard a systemd unit, assert its content: the `ExecStart` binary, or another line only the real unit has. `[ -e ]` passes for a masked unit. `[ -f ]` catches the mask but not a unit that runs the wrong thing.
- Add `systemd.services.<name>.enable = false` (or `systemd.sockets`/`timers` as appropriate) to the mutation list of any check that guards a unit, next to turning off the feature option. They produce different trees.
- The same masking applies to anything read from `etc."systemd/system"` or `etc."systemd/user"`: a symlink target check against the store, or `readlink -f` compared with `/dev/null`, also works when the unit has no distinctive line.

## See also

- [A check that reads an option value passes when the option is disabled or renamed](nix-check-reads-option-value-not-materialized-output.md) — moves the assertion onto the materialized output. This doc is the next step: the materialized output has a masked form that still looks present.
- [An assertion on an unconditionally set option compiles to a constant and can never fail](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) — reads the rendered `pcscd.socket` unit through `systemd.units.<name>.unit`, a different route with the same question of what a disabled unit leaves behind.
- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the general discipline of naming a mutation that turns each assertion red.
