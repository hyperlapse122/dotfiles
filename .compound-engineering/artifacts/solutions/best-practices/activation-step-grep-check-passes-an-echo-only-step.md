---
title: "A check that greps an activation step's arguments passes when the step only echoes them"
date: 2026-10-23
category: best-practices
module: "Home Manager activation checks (tests/darwin-outputs.nix)"
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "A flake check asserts a home.activation step by finding it in the generated activate script and grepping that script for the step's command or arguments"
  - "A check is re-pointed from one activation step to another, so it inherits the old assertion's shape"
  - "A check that builds only on macOS asserts what a nix-darwin Home Manager activation step does"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - flake-checks
  - home-manager
  - activation
  - mutation-testing
  - nix-darwin
  - nix
---

# A check that greps an activation step's arguments passes when the step only echoes them

## Context

The Pi paths and examples below describe the original incident. Pi provisioning
was retired in October 2026. The current behavioral owner is
`tests/omp-settings.nix`, which runs `tests/omp_settings_applied.py` against
materialized Home Manager activations, including the native Darwin fixture.
It redirects the real `ompSettings` block into a temporary home, executes it,
and checks restored settings, preserved skill files, and failure propagation.
Linux execution does not establish native Darwin execution; that remains a
separate platform check.

When OpenCode was removed on the `chore/remove-opencode` branch, `tests/darwin-outputs.nix` lost its assertion on the `opencodeSettings` activation step and the assertion was re-pointed at Pi's `piSettings` step. The re-pointed assertion had two predicates: the step's `_iNote "Activating %s" "piSettings"` line comes after `writeBoundary` in `$gen/activate`, and the script contains `--settings /Users/tester/.pi/agent/settings.json`.

The cross-model peer review found that both predicates still hold when the merger call in the step is replaced by `echo` of the same command line. The step order is unchanged, and the argument string is still in the script, so the check stays green while the step writes nothing. The `opencodeSettings` assertion it came from had the same shape and the same hole. The former `tests/pi.nix` did not cover it either, because its user entries came from NixOS configurations and Linux fixtures only, so no behavioral check ran the macOS step.

## Guidance

Run the activation step instead of grepping it, and assert the file it writes.

1. Extract the step's lines from `$gen/activate`: everything after its `_iNote "Activating %s" "<name>"` line up to the next step's note. The original `tests/darwin-outputs.nix` fix used a `stepBlock` helper built on `awk`; the OMP owner extracts its block in Python.
2. Take the paths the step uses from that block, not from the module: the merger binary (`/nix/store/.../bin/agent-settings`) and the `--declared` document.
3. Replace the real destination in the block with a scratch file, and fail when the replacement changes nothing, because then the step does not target the path the check names.
4. Run the redirected block with `bash -euo pipefail -c`.
5. Assert that the scratch file holds the required settings. The former `tests/pi_settings_applied.py` read the declaration's `set` keys and `setPaths` leaves. The OMP owner checks observable policy values, restores deliberately drifted settings, and verifies that invalid input propagates failure without replacing the file.

The original fix made an `echo`-only step fail with `the activation left no readable settings file`.

## Why This Matters

A text predicate on a generated script proves that some string is present, not that the command runs. Any change that keeps the string and drops the effect passes: a commented-out call, an `echo`, a `|| true` that hides a failed merge, or a guard that skips the call. For a settings merge, the effect that matters is the file on disk after activation, and only executing the step observes it.

macOS-only checks raise the stakes. `darwin-outputs` builds only on CI's `build-darwin` job, so a weak assertion there is the only guard on the macOS activation and is rarely run by hand.

## When to Apply

- Writing or re-pointing an assertion on a `home.activation` step that writes a file.
- Reviewing a check whose evidence is "the step exists" plus "the script mentions its arguments".
- Mutation-testing an activation check: replace the step's command with `echo` of the same line. If the check stays green, it does not test the step.

Steps that need the real home, network access, or a running service cannot always run in the build sandbox. For those, assert the strongest local effect the step produces, and say in the check which part stays unverified.

## Examples

Before, in `tests/darwin-outputs.nix` (both predicates pass for an `echo`-only step):

```sh
piSettings=$(step piSettings); piSettings=${piSettings:-0}
if [ "$piSettings" = 0 ] || [ "$piSettings" -le "$boundary" ]; then
  bad "the activation script has no piSettings step after writeBoundary"
elif ! grep -qF -- "--settings /Users/tester/.pi/agent/settings.json" "$gen/activate"; then
  bad "the Pi settings merge does not target /Users/tester/.pi/agent/settings.json"
fi
```

Historical fix (abridged from the same file before Pi retirement):

```sh
piBlock=$(stepBlock piSettings)
piDeclared=$(grep -oE -- '--declared[[:space:]]+/nix/store/[^[:space:]]+' <<<"$piBlock" | head -n1 | awk '{print $2}' || true)
piRedirected=${piBlock//"$piTarget"/"$piScratch"}
if [ "$piRedirected" = "$piBlock" ]; then
  bad "the Pi settings merge does not target $piTarget"
elif ! output=$(bash -euo pipefail -c "$piRedirected" 2>&1); then
  bad "the piSettings step fails on a scratch settings file:"$'\n'"$output"
elif ! output=$(python3 -I pi_settings_applied.py "$piDeclared" "$piScratch" 2>&1); then
  bad "the piSettings step does not write its declared settings:"$'\n'"$output"
fi
```

The fix was verified on Linux by taking the generated check script and the macOS fixture's activation text from `nix derivation show -r`, as [verify a Linux-only Nix check's text inputs on macOS through nix derivation show](verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md) describes in the other direction. Unmodified, the extracted logic exits 0 and writes the declared settings. With `echo` in front of the merger call, it exits 1.

## Related

- [A check that reads an option value passes when the option is disabled or renamed](nix-check-reads-option-value-not-materialized-output.md): the same proxy-instead-of-effect failure, on option values instead of activation text.
- [An unanchored grep fragment misses the argument that decides where a write lands](unanchored-grep-fragment-misses-destination-argument.md): a longer fragment fixes a wrong destination, but no fragment catches an `echo`-only step.
- [Mutation testing reveals decorative assertions in a Nix flake check](mutation-testing-reveals-decorative-nix-check-assertions.md): the `echo` replacement is the mutation to run against any activation check.
