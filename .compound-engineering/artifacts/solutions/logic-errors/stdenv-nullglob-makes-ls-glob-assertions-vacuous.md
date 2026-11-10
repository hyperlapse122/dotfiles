---
title: "stdenv's nullglob makes an `ls <glob>` assertion in a Nix check succeed when nothing matches"
date: 2026-10-06
category: logic-errors
module: "NixOS flake checks (tests/podman-containers.nix, tests/printing.nix)"
problem_type: logic_error
component: testing_framework
severity: medium
symptoms:
  - "podman-containers reported \"a target wants podman-prune.service\" on every configuration while no *.wants directory held the unit"
  - "The printing check passed with its gutenprint filter glob renamed to a pattern that matches no file"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - nullglob
  - shell-glob
  - flake-checks
  - mutation-testing
  - nix
---

# stdenv's nullglob makes an `ls <glob>` assertion in a Nix check succeed when nothing matches

## Problem

Every builder that sources stdenv's `setup.sh`, including `pkgs.runCommand`, runs with `shopt -s nullglob` (`pkgs/stdenv/generic/setup.sh:597` in nixpkgs). An unmatched glob then expands to nothing, so `ls <glob>` becomes a bare `ls` that lists the build directory and exits 0. An assertion that uses `ls` to test whether a glob matched reports a match whether or not one exists.

## Symptoms

- A draft of the podman-prune negative assertion, `if ls <tree>/*.wants/podman-prune.service >/dev/null 2>&1; then fail; fi`, failed on every configuration before the unit existed at all. The draft was replaced before it was committed.
- The positive form is worse because it fails silently. `tests/printing.nix` asserted the gutenprint CUPS filter with `if ! ls <drivers>/lib/cups/filter/rastertogutenprint.* >/dev/null 2>&1; then fail; fi`. In a mutation run with the glob renamed to `rastertonosuchfilter.*`, the check still passed.

## What Didn't Work

- Reading the assertion in an interactive shell: there nullglob is off, an unmatched glob stays literal, `ls` fails, and the assertion looks correct. The behavior only differs inside the stdenv builder.

## Solution

Iterate the glob and test each candidate. A loop over an empty expansion runs zero times under nullglob, and the `-e` test keeps it correct where nullglob is off and the literal pattern survives. Simplified from the two checks:

```sh
# Negative: no unit may want podman-prune.service
for wanted in "$tree"/*.wants/podman-prune.service; do
  if [ -e "$wanted" ]; then fail "a unit wants podman-prune.service"; fi
done

# Positive: at least one gutenprint filter must exist
gutenprint=
for filter in "$drivers"/lib/cups/filter/rastertogutenprint.*; do
  if [ -e "$filter" ]; then gutenprint=1; fi
done
if [ -z "$gutenprint" ]; then fail "no gutenprint filter"; fi
```

Both checks now use this pattern, each with a comment naming the trap.

## Why This Works

The loop's body is the test, so an empty expansion produces no iterations and no match, which is the truth. `ls` instead receives the expansion as its argument list, and an empty argument list is a valid `ls` call with its own success status.

## Prevention

- In a check builder, never use `ls`, `stat`, or another command whose zero-argument form succeeds to ask whether a glob matched. Use a loop with `[ -e ]`, or count an array built from the glob.
- When adding or auditing a glob assertion, run the mutation that should trip it: rename the glob to a pattern that matches nothing (positive form), or add a matching file (negative form), and confirm the check turns red. A check that stays green under that mutation is decorative; see [mutation testing for check assertions](../best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md).
- `grep -qs <pattern> <glob>` has a related exposure: with no file arguments grep reads stdin instead, so a negative "no file contains X" check passes without inspecting any file. Assert separately that the glob matched, or loop.
