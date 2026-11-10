---
title: "An unanchored grep fragment misses the argument that decides where a write lands"
date: "2026-09-23"
category: best-practices
module: "NixOS flake checks (grep fragment against a multi-argument invocation)"
problem_type: best_practice
component: testing_framework
severity: medium
root_cause: logic_error
resolution_type: workflow_improvement
related_components:
  - tooling
tags:
  - mutation-testing
  - flake-checks
  - nix
  - grep
  - kwriteconfig6
  - powerdevil
---

# An unanchored grep fragment misses the argument that decides where a write lands

## Context

`tests/logind-lid-switch.nix` and `home/h82/desktop/kde/power-lid.nix` were removed with the ThinkPad host in e857618. The example is kept because the pattern recurs.

`tests/logind-lid-switch.nix` guards the KDE Powerdevil lid-action configuration `home/h82/desktop/kde/power-lid.nix` writes via eight `kwriteconfig6 --file powerdevilrc --group <profile> --group SuspendAndShutdown --key <key> ...` invocations. Its `assertPowerdevilHandled` helper reads the materialized `home.activation.kdePowerLid` script and asserts each invocation's shape is present, using `grep -Fq` (substring match) against fragments such as `--group Battery --group SuspendAndShutdown --key LidAction -- 1`.

This repository already carries six learnings about checks that pass without proving what they claim. None of them predicted this one: the assertion here is sound by every test those six apply. The shell can fail (`if ! grep ...; then exit 1; fi`, never a bare `! grep` under `set -e`). The value read is materialized output — the rendered activation script — not an unreachable option. The fixture states genuinely diverge across the three `assertHost`-style calls (at the time: ThinkPad production, ThinkPad bootstrap, MS-7D91). No operand folds to a constant the module under test cannot change. No shell comparison sees an empty numeric operand. All five checks pass, and the check still could not tell a correct write from one aimed at the wrong file.

## The practice

**When an assertion's expected substring is a fragment of a multi-argument invocation, include the argument that picks the destination, not only the arguments that describe the value.** `kwriteconfig6 --file powerdevilrc --group Battery --group SuspendAndShutdown --key LidAction -- 1` bundles two roles into one line: `--file powerdevilrc` says *where* the write goes, and the rest says *what* it writes. A fragment built only from the second half is blind to the first — it matches identically whether the real invocation targeted `powerdevilrc` or an unrelated file, because `grep -Fq` (and even an anchored `grep -Fxq`, since these are fragments rather than whole lines) has no way to know the destination was ever part of the claim.

```nix
# before: matches regardless of --file
"--group Battery --group SuspendAndShutdown --key LidAction -- 1"

# after: the destination is part of what must match
"--file powerdevilrc --group Battery --group SuspendAndShutdown --key LidAction -- 1"
```

## What was verified

Two rounds, each `nix build --no-link .#checks.x86_64-linux.logind-lid-switch`:

| Round | Mutation | Result |
| --- | --- | --- |
| 1 (before the fix) | `--file powerdevilrc` -> `--file WRONGFILE.rc` on the Battery `LidAction` write only | green — the fragment still matched somewhere in the script |
| 2 (after the fix, same mutation) | identical mutation, expected fragments now include `--file powerdevilrc` | red: `ThinkPad-X1-Carbon-Gen-11: kdePowerLid activation script is missing: --file powerdevilrc --group Battery --group SuspendAndShutdown --key LidAction -- 1` |

The same tree and the same mutation go from a false pass to a correct failure purely by adding the discriminating argument to the expected string.

## How to apply

- When a check's expected value is a fragment of a longer shell invocation — not a whole line, not a whole file — ask which argument in the real invocation actually decides the outcome the check claims to guard, and confirm that argument is inside the fragment, not merely adjacent to it in the source.
- This generalizes past `--file`: any invocation with a destination or selector argument separate from its value arguments (an `--output`, a `--target`, a `--namespace`, a table or key name passed alongside a value) can be matched by a fragment that omits the selector, and the check will pass on a write aimed at the wrong destination.
- Mutating only the value (the class the existing six learnings already cover) is not sufficient coverage for this class of check. Add a destination mutation as its own round: change what the invocation targets, keep the value the same, and confirm the check still catches it.
- A sound assertion, materialized-output evidence, a diverged fixture, no constant operand, and no empty-operand comparison are five different questions. This is a sixth: once you assemble the real invocation from the source that produces it, does the matched fragment carry every argument the invocation needed to reach the outcome being asserted?

## See also

- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md) — the assertion's shell cannot fail.
- [A mutation that only breaks Nix evaluation proves nothing about a check](unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md) — the mutation never reaches the assertion.
- [A check that reads an option value instead of the materialized output](nix-check-reads-option-value-not-materialized-output.md) — the assertion reads a proxy for the property; this doc's assertion already read the materialized output and still missed the destination.
- [Converged fixture state defeats mutation testing](converged-fixture-state-defeats-nix-check-mutation-testing.md) — the fixture cannot distinguish correct from buggy; here the fixture (at the time, three real hosts) diverges correctly, and the fragment itself is what is blind.
- [An assertion on an unconditionally set option compiles to a constant](nix-check-assertion-on-unconditional-option-folds-to-a-constant.md) — the operand cannot vary; here it varies (the check does read three different hosts' scripts) and still cannot go red on this one dimension.
- [A nullable option reaches a shell comparison as an empty word](nullable-option-empty-operand-passes-a-shell-comparison.md) — a shell-level blind spot at the value's type boundary; this is a text-level blind spot at the fragment's boundary.
- [KDE Powerdevil overrides systemd-logind's lid and power-key settings](../integration-issues/kde-powerdevil-overrides-logind-lid-switch-settings.md) — the companion learning from the same change: why this check exists at all.
- [A check that greps an activation step's arguments passes when the step only echoes them](activation-step-grep-check-passes-an-echo-only-step.md) — a full, anchored fragment still passes when the step's command is replaced by `echo`; running the step catches that.

## Out of scope

Whether Powerdevil's own runtime actually applies a written `powerdevilrc` value (live-reload versus needing a relogin) is not a build-time question; it is a hardware check rather than a repository check (see `CONCEPTS.md` and `AGENTS.md`). This check proves the activation script writes the right value to the right file, nothing about the running KDE session's response to it.
