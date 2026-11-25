---
title: "A failed verification against a superseded main opens a stale reconciliation PR"
date: "2026-11-26"
category: logic-errors
module: "CI dependency publication (scripts/ci-update-publish, .github/workflows/update-dependencies.yml)"
problem_type: logic_error
component: testing_framework
severity: medium
symptoms:
  - "The scheduled dependency update opened a reconciliation PR for checks.x86_64-linux-omp, but main had already completed that check's fix before the PR was created"
  - "The reconciliation body said to push a fix to the branch even though the logged failure no longer reproduced on main"
  - "Publication of the dependency candidate was blocked behind a failure of a base the run no longer used"
root_cause: missing_workflow_step
resolution_type: code_fix
tags:
  - update-dependencies
  - reconciliation
  - verify
  - stale-base
  - github-actions
  - step-summary
---

## Problem

The scheduled dependency-update publisher verified its candidate before fetching `main`, and `set -e` exited at the first verification failure before `sync_main` ran. When a fix reached `main` during the long verification, the run could not re-verify against it and opened a reconciliation PR for a defect `main` no longer had (PR #317 in `hyperlapse122/dotfiles`).

## Symptoms

- Run `45544603113` started at 04:07Z from the commit that merged PR #314; the run took about 84 minutes, with its publish/verify step about 79. `main` moved to PR #315's merge at 04:38Z, which completed the `omp` config mirror in `tests/omp.nix`.
- The reconciliation PR's failure log named `checks.x86_64-linux-omp`; that check passes on the `main` the PR was about to merge into.
- The workflow reported `Failure stage: verification` and waited for a human to push a fix against a base the run had already superseded.

## What Didn't Work

The first hypothesis was the `omp` test expectation. It was stale when the run started, but another change had already completed the mirror on `main` (PR #315), so editing it on the reconciliation branch would have duplicated a merged fix and left the stale-base mechanism in place.

Reading only the reconciliation body cannot settle whether the failure still reproduces. The PR is built from the `origin/main` the run fetched in `prepare_dependencies`, not from the `main` that exists when the PR is opened.

## Solution

`scripts/ci-update-publish` now treats a verification failure as a reason to re-synchronize before reporting it:

```bash
summary_size=0
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$GITHUB_STEP_SUMMARY" ]; then
  summary_size=$(wc -c < "$GITHUB_STEP_SUMMARY" | tr -d ' ')
fi

verified=0
if verify; then
  verified=1
fi
before=$(git rev-parse HEAD)
sync_main
if [ "$verified" -eq 0 ] && [ "$(git rev-parse HEAD)" != "$before" ]; then
  # The retry verified the rebased candidate; drop the superseded attempt's
  # failure report from this step's summary.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$GITHUB_STEP_SUMMARY" ]; then
    truncate -s "$summary_size" "$GITHUB_STEP_SUMMARY" || true
  fi
fi
if [ "$verified" -eq 0 ] && [ "$(git rev-parse HEAD)" = "$before" ]; then
  record_stage verification
  echo 'Verification failed and main has not moved; nothing newer to retry against.'
  exit 1
fi
```

`sync_main` keeps its existing contract: it fetches `main`, rebases when `main` moved, and re-runs `verify` when the rebase leaves candidate commits. The change makes the failure path reach that contract: it reports the superseded attempt's failure only when `main` did not move, so a red base that is fixed mid-run is re-verified instead of reconciled. A retry that itself fails still fails and pushes nothing.

A successful retry truncates this step's `$GITHUB_STEP_SUMMARY` back to the byte offset captured before the first attempt. The offset preserves anything written earlier in the step while removing the superseded attempt's `verification failed` sections, which `ci-update-verify` appends. The truncation is diagnostic-only and cannot fail the publication.

## Why This Works

The causal chain is an ordering gap, not a wrong check. `verify` is expensive and runs against the tree the run started with. `sync_main` is the only code in the publisher that fetches `main` and re-verifies a rebased tree, and the old top-level sequence was `verify` then `sync_main`; a non-zero `verify` ended the script at `set -e` before the fetch. The fail-fast behavior was correct for a candidate failure and wrong for a failure of a base that no longer exists.

On the run above, `main` advanced 31 minutes after the run started, and the fix merged before the reconciliation step ran. Re-fetching at that point would have rebased the candidate, re-run the same verifier, and published the dependency bump. The retry reuses whatever the Nix store still holds; the verifier's `min-free`/`max-free` options can reclaim earlier closures, so only still-cached derivations avoid a rebuild.

Keeping `failure_stage` as `verification` when exiting after an unchanged `main` matters because `sync_main` records `fetch` and `rebase` stages. Without the restore, the reconciliation report would attribute a verification failure to a fetch.

## Prevention

- The regression coverage lives in `tests/update-workflow.py`: the behavioral scenario "a failure against a superseded base retries instead of reconciling" moves `main` on the publish fetch, fails only round 1, and asserts two verification rounds, a verified push, no reconciliation, and a clean step summary. The mutations "superseded-base retry removed" and "superseded failure summary retained" turn each half red. This seam catches publish-ordering races against a moving `main`; it does not catch a real Nix build failure, which the individual-failure scenarios simulate separately.
- When a reconciliation PR appears, fetch `origin/main` and check whether the logged failure still reproduces there before pushing a fix to the branch. The PR body describes the run, not current `main`.
- Keep the failure stage restored before any early exit that follows `sync_main`.

Related: [A `$?` read after `cmd | tee` captures tee's status, so a CI verify step reports success for every failure](pipe-to-tee-exit-status-reports-success-in-github-actions-step.md) covers the same verification gate and step-summary machinery from the opposite direction (the gate reporting success for a failure); [An unset init.defaultBranch leaves a bare repo's HEAD dangling for a second clone](../best-practices/unset-defaultbranch-leaves-bare-repo-head-dangling-for-second-clone.md) documents the concurrent-push fixture this retry coverage builds on.
