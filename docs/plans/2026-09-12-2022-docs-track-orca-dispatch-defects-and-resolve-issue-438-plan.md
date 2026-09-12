---
title: Track Orca dispatch defects and resolve issue 438 - Plan
type: docs
date: 2026-09-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/438
---

# Track Orca dispatch defects and resolve issue 438 - Plan

## Goal Capsule

- **Objective:** Issue #438 in hyperlapse122/dotfiles is cleanly and completely resolved with all acceptance criteria accounted for, residual findings updated with upstream issue tracking, and no unapproved comments or issues created on external repositories.
- **Means:** Update `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` with upstream tracking for Defect 3 (`stablyai/orca#19166`), record local tracking for Defects 1 and 2, record the guide-owned resolution for acceptance item 3, post the resolution summary comment on #438, and close the issue.
- **Authority:** The Product Contract requirements below govern behavior. The settled decisions from brainstorming govern scope.
- **Execution profile:** Documentation updates and issue closeout. Verification via CI check scripts and GitHub CLI state.
- **Stop conditions:** Stop and report if `stablyai/orca#19166` is deleted or inaccessible, or if GitHub CLI lacks credentials to manage hyperlapse122/dotfiles issues.
- **Tail ownership:** The pipeline caller (`lfg`) owns commit, push, PR creation, CI babysitting, and merging.

---

## Product Contract

### Summary

Resolve GitHub issue #438 by completing its two outstanding acceptance criteria:
1. Acceptance item 3 (residency verification command): Confirm and record the resolution that the instruction core remains command-agnostic, directing "one Orca-side query of that dispatch's state", while the version-matched guide owns exact command spellings (`worker-show`, `worker-list`).
2. Acceptance item 6 (upstream reporting): Link Defect 3 to upstream issue `stablyai/orca#19166`, record that Defects 1 and 2 remain documented locally in `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` without creating external issues or comments, and record that all six acceptance criteria of #438 are satisfied.

### Problem Frame

Issue #438 reported four defects in dotfiles and two upstream Orca defects when review workers were dispatched. Earlier PRs resolved the primary defects:
- PR #439 added the review dispatch contract, deadline backstops, release requirements, and bare-`orca` wrapper.
- PR #477 added explicit prohibitions against shell wait loops (`until`, `while`, `sleep` polls) in the shared instruction core.
- Commit `133630a` (Issue #442) tightened the residency clause against `retained` release receipts.
- PR #497 moved the coordinator dispatch rules into `orchestration-coordinator.tmpl`.

Two acceptance items remained open on #438:
1. Upstream defect reporting: Drafts were staged in `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` during unattended runs. Investigation showed that Defect 3 (`identity_unproven` release receipts) was subsequently reported upstream by the community as `stablyai/orca#19166`. The user directed that no new issues or comments be created on external repositories, and that issues be tracked/watched locally instead.
2. Acceptance item 3 (residency verification command): The coordinator instructions deliberately avoided hardcoding a version-specific Orca command spelling in the shared templates. In brainstorming, the user settled on accepting the guide-owned spelling as sufficient, maintaining the command-agnostic instruction core.

### Key Decisions

- (session-settled: user-directed — chosen over pinning an explicit command: keeps the instruction core command-agnostic across Orca versions and CLI flag evolutions) Keep residency verification command guide-owned: The coordinator contract in `.chezmoitemplates/orchestration-coordinator.tmpl` requires "one Orca-side query of that dispatch's state" and the version-matched guide (`orca-ide skills get orchestration`) provides `worker-show --dispatch <id> --json` and `worker-list --run <run_id> --terminal-state reclaimable --json`.
- (session-settled: user-directed — chosen over filing new issues or comments on stablyai/orca: user directed to watch/track rather than creating comments or issues in external repositories) Track existing upstream issues locally without creating issues or comments on `stablyai/orca`: Defect 3 is linked to `stablyai/orca#19166` in `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md`, and Defects 1 and 2 remain documented in that file as local tracking.
- Branch renaming before push: The checked-out branch `hyperlapse122/blobfish` carries an Orca-worktree name. Per user rules, it must be renamed in place to a descriptive Git-Flow slug (`docs/track-orca-dispatch-defects-close-438`) before push/PR.

### Requirements

- R1. `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` is updated to record upstream issue `stablyai/orca#19166` for Defect 3.
- R2. `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` records the user directive that Defects 1 and 2 are tracked locally without creating external issues or comments on `stablyai/orca`.
- R3. `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` records the resolution of acceptance item 3 (guide-owned residency verification query).
- R4. All repository CI tests and checks pass without regressions.
- R5. Issue #438 in `hyperlapse122/dotfiles` is updated with a comprehensive resolution comment detailing how all six acceptance criteria were fulfilled, and closed.

### Scope Boundaries

- Out of scope: Creating any issues, pull requests, or comments on `stablyai/orca`.
- Out of scope: Modifying `.chezmoitemplates/orchestration-coordinator.tmpl` or `.chezmoitemplates/agents-instructions.tmpl` (the guide-owned query wording is settled and kept).

---

## Planning Contract

- Risk: Modifying `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` must preserve valid markdown syntax and clear historical tracing.
- Conventions: Follow existing formats in `docs/residual-review-findings/`.
- Pre-conditions: Working tree is clean on branch `hyperlapse122/blobfish`.

---

## Implementation Units

### Unit 1: Update residual review findings documentation

- **Goal:** Update `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` to link upstream issue tracking and record acceptance criteria resolutions.
- **Files:** `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` (modify).
- **Details:**
  - In section "Defect 3 — a `retained` release receipt does not say whether anything is still resident": Add upstream tracking link to `stablyai/orca#19166` ("worker-release can never reclaim a settled worker whose PTY vanished (retained/identity_unproven on every retry)").
  - In section "Why these are recorded rather than filed": Update text to state that Defect 3 is tracked upstream at `stablyai/orca#19166`, and Defects 1 and 2 are tracked locally in this document per user directive without creating external issues or comments.
  - Add a summary section documenting the status of all six acceptance criteria from issue #438, explicitly confirming that acceptance item 3 is satisfied via the version-matched guide's query commands (`worker-show`, `worker-list`).
- **Acceptance:**
  - File contains markdown links to `https://github.com/stablyai/orca/issues/19166` and `https://github.com/hyperlapse122/dotfiles/issues/438`.
  - Content reflects the settled decisions.

### Unit 2: Verify test gates and rename branch

- **Goal:** Verify that all repository test suites pass and rename the local branch to a compliant Git-Flow slug.
- **Files:** Git branch state.
- **Details:**
  - Run `.ci/test-agent-instructions.sh` and other core CI scripts.
  - Rename branch `hyperlapse122/blobfish` in place to `docs/track-orca-dispatch-defects-close-438`.
- **Acceptance:**
  - All CI tests exit 0.
  - `git branch --show-current` outputs `docs/track-orca-dispatch-defects-close-438`.

---

## Verification Contract

- Run `.ci/test-agent-instructions.sh` to confirm instruction rendering and fixtures remain intact.
- Run `git diff` to verify only the intended documentation changes are made.
- Verify `gh issue view 438` can be commented on and closed after PR merge.

---

## Definition of Done

1. `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` is updated and committed.
2. Code review and simplification passes complete cleanly.
3. PR is opened and merged to main via autonomous pipeline.
4. Issue #438 has a resolution comment and is closed.
