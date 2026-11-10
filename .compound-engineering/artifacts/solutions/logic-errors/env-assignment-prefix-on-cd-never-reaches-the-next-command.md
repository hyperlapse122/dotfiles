---
title: "An env assignment prefixed to `cd` never reaches the command after `&&`, so a PATH stub test passes vacuously"
date: 2026-10-09
category: logic-errors
module: "Shell tests run by flake checks (tests/lint-staged-markdown.sh)"
problem_type: logic_error
component: testing_framework
severity: medium
symptoms:
  - "A scenario meant to prove markdownlint-cli2 is not called passed even with the script's early exit removed"
  - "The failing stub placed on PATH never printed its marker"
root_cause: logic_error
resolution_type: test_fix
related_components:
  - tooling
tags:
  - shell
  - path-stub
  - env-assignment
  - mutation-testing
  - flake-checks
---

# An env assignment prefixed to `cd` never reaches the command after `&&`, so a PATH stub test passes vacuously

## Problem

A variable assignment written before a simple command applies to that one command only. In `(PATH="$stub_dir:$PATH" cd "$repo" && bash "$script")` the assignment prefixes the `cd` builtin, so `bash "$script"` after `&&` runs with the original `PATH`. A test that relies on a stub being first on `PATH` then never exercises the stub, and passes whether or not the code under test calls the tool.

## Symptoms

- The "staging only `flake.nix` exits 0 without running markdownlint-cli2" scenario in `tests/lint-staged-markdown.sh` passed against a mutant of `scripts/lint-staged-markdown` with its early `exit 0` (`scripts/lint-staged-markdown:12`) removed, which does call markdownlint-cli2.
- The stub, which prints `FAIL_STUB_CALLED` and exits 99, produced no output.

## What Didn't Work

The scenario looked correct on review and passed on the real script, so nothing flagged it. It only showed up when host inspection of the delegated implementation asked whether the stub could ever be reached. The real `markdownlint-cli2` found nothing to lint and exited 0, which is the same result the scenario expects from a script that never calls the tool.

## Solution

Put the assignment on the command that has to see it:

```bash
# Before: PATH applies only to cd
(PATH="$stub_dir:$PATH" cd "$repo3" && bash "$script") || fail "staging non-markdown called markdownlint-cli2"

# After: PATH applies to the script run
(cd "$repo3" && PATH="$stub_dir:$PATH" bash "$script") || fail "staging non-markdown called markdownlint-cli2"
```

The fixed line is `tests/lint-staged-markdown.sh:133`. With it, the early-exit mutant fails the scenario with `FAIL_STUB_CALLED` and `staging non-markdown called markdownlint-cli2`.

## Why This Works

Bash treats `NAME=value cmd args` as a temporary assignment for `cmd`'s environment, and for a builtin such as `cd` the assignment is dropped once the builtin returns. Each command in an `&&` list is a separate simple command, so the prefix never carries over. Exporting inside the subshell (`(export PATH=...; cd ... && bash ...)`) or prefixing the command that runs the code under test both make the stub visible.

## Prevention

- When a test places a stub on `PATH`, prefix the assignment to the command that runs the code under test, not to `cd` or another setup step in the same list.
- Make the stub fail loudly (non-zero exit and a marker line), and confirm the scenario with a mutant that does call the tool, as [mutation testing for check assertions](../best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md) describes. A passing "not called" assertion proves nothing until a mutant that calls the tool makes it fail.
- [Fixture state that cannot distinguish a bug from its fix](../best-practices/converged-fixture-state-defeats-nix-check-mutation-testing.md) and [`$?` after `| tee`](pipe-to-tee-exit-status-reports-success-in-github-actions-step.md) cover other ways a PATH-stub test can pass on the wrong code.
