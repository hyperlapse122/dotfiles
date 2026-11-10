---
title: "A $? read after `cmd | tee` captures tee's status, so a CI verify step reports success for every failure"
date: 2026-10-01
category: logic-errors
module: "CI workflow gating (update-dependencies.yml Verify updates step)"
problem_type: logic_error
component: testing_framework
severity: high
symptoms:
  - "The Verify updates step reported status=success when nix fmt, nix flake check, or a build failed"
  - "The update-dependencies job would push failing dependency updates straight to main"
  - "Every captured X_EXIT=$? read 0 because $? after a pipeline is tee's status"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - development_workflow
  - tooling
tags:
  - github-actions
  - pipefail
  - pipestatus
  - tee
  - exit-status
  - update-dependencies
  - flake-checks
  - nix-sandbox
  - mutation-testing
---

# `$?` after `| tee` let the dependency-update gate pass every failure

## Problem

The scheduled dependency-update workflow decides whether to push straight to `main` from one output: `steps.verify.outputs.status`. The push step runs only when that output is `success` (the push step's `if:` in `.github/workflows/update-dependencies.yml`). The "Verify updates" step that sets it piped each check through `tee` so the log could go into the step summary, then read `$?` for the check's exit code. In a pipeline without `pipefail`, `$?` is the status of the last command, which here is `tee`. `tee` almost always succeeds, so the step wrote `status=success` whatever `nix fmt` or `nix flake check` returned. Broken updates could therefore land on `main` with no human in the loop.

Before the fix (`git show a3f409f:.github/workflows/update-dependencies.yml`, lines 95-104):

```yaml
        run: |
          set +e
          nix fmt -- --ci 2>&1 | tee fmt.log
          FMT_EXIT=$?
          nix flake check --print-build-logs 2>&1 | tee check.log
          CHECK_EXIT=$?
          set -e

          if [ "$FMT_EXIT" -eq 0 ] && [ "$CHECK_EXIT" -eq 0 ]; then
            echo "status=success" >> "$GITHUB_OUTPUT"
```

The step declares no `shell:`. GitHub Actions runs a `run:` block with no `shell:` key as `bash -e {0}`. Only an explicit `shell: bash` gets `bash --noprofile --norc -eo pipefail {0}`. So nothing in the step's environment set `pipefail`, and `set +e` also stopped `-e` from aborting on a failing pipeline (which, without `pipefail`, it would not have done anyway).

The fix (issue #140) is merged.

## Symptoms

- The step reported `status=success` and printed "All verification checks passed." whatever `nix fmt -- --ci` or `nix flake check` returned, so the push step could commit to `main` and push.
- The "Verification failed (fmt: …, check: …)" branch and its step-summary tail of `check.log` could not run, because `FMT_EXIT` and `CHECK_EXIT` were always `tee`'s `0`.
- Nothing looked wrong in the logs: the failing command's output was printed in full by `tee`, the step itself was green, and the next step ran as it should for a passing gate.
- Reproduced: running the original `tests/update-dependencies-verify-status.sh` check (now consolidated into `tests/update-dependencies-reconcile.sh`) against the base commit's workflow fails on the first case:

  ```text
  update-dependencies-verify-status: FAIL: a failing nix fmt reported 'status=success', so the push step would land the update on main
  ```

## What Didn't Work

- **A stub `nix` with `#!/usr/bin/env bash`.** The first sandboxed run of the new flake check failed every case, including the all-success one. The Nix build sandbox has no `/usr/bin/env`, so each call to the stub exited 127. The step script read that as a failing command, so each run reported `status=failure`. That also made the first round of mutation testing worthless: every mutant "failed" the check for the wrong reason, so the round could not show that any assertion did its job. The stub instead uses the shebang of the bash running the test, `#!$BASH`, which exists inside the sandbox (`tests/update-dependencies-reconcile.sh`, consolidated from the original `tests/update-dependencies-verify-status.sh`):

  ```bash
    # The running bash, not /usr/bin/env: the Nix build sandbox has no env.
    cat >"$dir/bin/nix" <<EOF
  #!$BASH
  ```

  Mutation testing was then run again. Three mutants of the workflow step each failed in the builder with the check's own message: dropping the `"$VM_EXIT" -eq 0` clause, reverting `${PIPESTATUS[0]}` to `$?`, and deleting the `.#vmChecks.all` build.

- **Appending the VM-test log to `check.log`.** An earlier commit on the same branch already used `PIPESTATUS`, but it sent the new VM-test build into the same file with `tee -a check.log`. The failure summary prints `tail -n 50 check.log`. With both logs in one file, a failing `nix flake check` followed by a long VM build log would push the flake-check error out of those 50 lines. The test caught this: against that commit's workflow, all four status cases pass but the check fails with `the VM build log is not in vm-check.log`. The current step writes the VM log to its own file and gives each failing command its own summary section.

## Solution

Read each command's own exit status from `PIPESTATUS[0]` on the line straight after its pipeline, and give each logged command its own log file (the `Verify updates` step in `.github/workflows/update-dependencies.yml`):

```yaml
        run: |
          set +e
          # The step runs without pipefail, so $? after a pipe is tee's
          # status; PIPESTATUS[0] is the command's own.
          nix fmt -- --ci 2>&1 | tee fmt.log
          FMT_EXIT=${PIPESTATUS[0]}
          nix flake check --print-build-logs 2>&1 | tee check.log
          CHECK_EXIT=${PIPESTATUS[0]}
          # The VM tests live outside `nix flake check`. Their own log keeps a
          # flake check failure from being pushed out of the tail below.
          nix build --no-link --print-build-logs .#vmChecks.all 2>&1 | tee vm-check.log
          VM_EXIT=${PIPESTATUS[0]}
          set -e

          if [ "$FMT_EXIT" -eq 0 ] && [ "$CHECK_EXIT" -eq 0 ] && [ "$VM_EXIT" -eq 0 ]; then
            echo "status=success" >> "$GITHUB_OUTPUT"
```

The failure summary then tails `check.log` only when `CHECK_EXIT` is non-zero and `vm-check.log` only when `VM_EXIT` is non-zero (that step's failure summary). `/vm-check.log` joins `/fmt.log` and `/check.log` in `.gitignore:15-17`, so the push step's catch-all commit does not pick it up. `tests/update-dependencies-reconcile.sh` writes `fmt.log`, `check.log`, and `vm-check.log` into its sandbox clone and asserts that none of the three logs gets committed.

`tests/update-dependencies-reconcile.sh` (consolidating the former `tests/update-dependencies-verify-status.sh` and `tests/update-dependencies-push-order.sh` scripts) runs the step's real script instead of grepping it for patterns:

- It extracts the `run:` block of the "Verify updates" step structurally from `.github/workflows/update-dependencies.yml` with `yq` and `jq`.
- It runs the block the way GitHub runs a step with no `shell:`, `bash -e -c "$verify_script"`, with a stub `nix` first on `PATH` and `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY` pointing at scratch files.
- The stub fails `fmt`, `flake`, and `build` in turn, and each run must write `status=failure`. A fourth run where nothing fails must write `status=success`.
- It asserts that the failing VM build's output is in `vm-check.log` and not in `check.log`.

The check is registered in `flake.nix` as `update-dependencies-reconcile`, so `nix flake check` runs it.

## Why This Works

Bash sets `PIPESTATUS` after every pipeline: an array with one exit status per stage. `${PIPESTATUS[0]}` is the status of `nix …`, the first stage, whatever `tee` returned and whether or not `pipefail` is on. The next command overwrites the array, including a plain assignment, so it must be read on the line right after the pipeline. The step does this: each `*_EXIT=${PIPESTATUS[0]}` sits directly under its pipeline.

The test catches the bug because it executes the script under the same shell options as GitHub's default and only varies which command fails. A step that reads `$?` after `| tee` reports success when `fmt` fails. A step that stops building the VM tests, or stops checking `VM_EXIT`, reports success when only `build` fails. A step that always reports failure is caught by the all-success case. Each of these mutants was confirmed to fail the check once the stub could run in the sandbox.

## Prevention

- In a GitHub Actions step with no `shell:` key, never read `$?` after a pipeline. The default shell is `bash -e {0}` without `pipefail`, so `$?` belongs to the last stage. Read `${PIPESTATUS[0]}` straight after the pipeline. Alternatively, declare `shell: bash`, which adds `-o pipefail`, but a step that uses `set +e` to collect several statuses still needs each status read on the next line.
- Treat any step whose output gates a push, merge, or release as code that needs a test. Extract its `run:` block and execute it against stubbed tools under the shell flags GitHub uses. Grepping the YAML for `PIPESTATUS` would not catch a reverted `$?` in one of three places.
- Inside a Nix build sandbox, write stub executables with `#!$BASH` (or another absolute store path), not `#!/usr/bin/env bash`. The sandbox has no `/usr/bin/env`, and a stub that exits 127 looks just like a stub that was meant to fail.
- Before trusting mutation-test results, run the unmutated check in the sandbox and see it pass. If the baseline fails, every mutant "fails" for the same unrelated reason and the round proves nothing.
- Give each command whose log a later step tails its own log file. Appending a second command's output to a file that is read with `tail` can push the first command's error out of view.

## Related

- [Mutation testing reveals decorative assertions in a Nix flake check](../best-practices/mutation-testing-reveals-decorative-nix-check-assertions.md): the same family of guard that always passes; this check was mutation-tested by reverting `${PIPESTATUS[0]}` to `$?`.
- [A mutation that only breaks Nix evaluation proves nothing about a check](../best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md): a mutation round must fail for the check's own reason, which the 127-exiting stub defeated here.
- [Nix check reads an option value, not the materialized output](../best-practices/nix-check-reads-option-value-not-materialized-output.md): the new check runs the real step text rather than grepping the YAML.
