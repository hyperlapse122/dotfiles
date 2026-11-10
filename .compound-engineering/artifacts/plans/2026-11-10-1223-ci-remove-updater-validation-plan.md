---
title: Publish automatic pin updates without Validation - Plan
type: ci
date: 2026-11-10
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Publish automatic pin updates without Validation - Plan

## Goal Capsule

- **Objective:** Automatic font, harness plugin, and personal application updates reach the default branch without waiting for CI validation.
- **Means:** Remove prepublication Validation from the three automatic update workflows.
- **Product authority:** The owner chose publication without validation over targeted checks, full-suite stabilization, and a PR-based update flow.
- **Open blockers:** None.

---

## Product Contract

### Summary

Publish generated pin updates directly after successful generation.
Handle problems discovered after publication as separate work.

### Problem Frame

Automatic pin updates currently require the shared Test workflow to succeed before publication.
The owner reports that repeated Validation failures prevent useful updates, while PR failures can usually be resolved by retrying.
Observed update failures include a font release download returning HTTP 500 and a harness plugin update blocked by unrelated application downloads and a native application timeout.
These observations establish failure modes, not an aggregate failure rate.

### Key Decisions

- **Remove the publication validation gate.** Governs R1 and R2. (session-settled: user-directed — chosen over targeted validation, full-suite stabilization, and PR-based updates: the owner wants automatic updates to proceed and problems handled separately.)
- **Keep this change limited to automatic updates.** Governs R3–R6. (session-settled: user-approved — chosen over changing ordinary CI or adding replacement checks: the owner accepted the scoped removal and its publication consequences.)

### Requirements

**Publication policy**

- R1. Font, harness plugin, and personal application update workflows must publish successfully generated changed candidates without invoking the shared Test workflow or awaiting any replacement validation.
- R2. Problems discovered in published updates must be handled separately rather than introducing a new prepublication or postpublication validation gate in this change.

**Existing behavior**

- R3. Preserve candidate generation, immutable artifact handoff, generated-file-only publication, and successful no-change exits; personal application updates continue to include the Synthetic model lock.
- R4. Generation and publication failures must remain failures rather than being treated as successful updates.
- R5. Preserve ordinary push, PR, and manual Test behavior, along with scheduling and manual invocation of the three updaters.
- R6. Preserve the separate harness shared-skill drift report, including its existing failure signal and reviewed-pin retention behavior.

### Key Flow

A scheduled or manual updater generates its candidate pins and passes the artifact to publication under R1 and R3.
Generation errors and publication errors follow R4.
A defect discovered after publication follows R2; no new automated recovery flow is introduced.

### Acceptance Examples

- AE1. **Changed candidate:** Given a successfully generated candidate for any of the three updaters, publication proceeds without launching Test, even if an unrelated native check would fail. Covers R1.
- AE2. **No changes:** Given candidate locks equal to the checked-out locks, publication exits successfully without a new commit. Covers R3.
- AE3. **Operational failure:** Given a generation error or a rejected publication push, the updater reports failure and does not claim that publication succeeded. Covers R4.
- AE4. **Ordinary code change:** Given an ordinary push, PR, or manual Test invocation, its existing test coverage remains available. Covers R5.
- AE5. **Shared-skill drift:** Given detected shared-skill drift, the existing report may still make the workflow fail independently of whether plugin pins were published. Covers R6.
- AE6. **Published defect:** Given a defect discovered after publication, resolving it is separate work and does not trigger a newly introduced validation or rollback mechanism. Covers R2.

### Scope Boundaries

- No PR CI stabilization, event deduplication, test matrix redesign, or test removal.
- No new retries, monitoring, postpublication test workflow, or automatic rollback.
- No changes to resolver integrity checks or the shared-skill review policy; see R3, R4, and R6.
- No applying personal configuration or publishing candidate updates as part of this requirements artifact.

### Dependencies and Consequences

The existing personal application updater explicitly notes that GITHUB_TOKEN pushes do not start push workflows.
Removing its reusable Test call therefore does not imply that ordinary CI will automatically validate the bot's published commit.
The owner accepted this consequence when confirming scope.

### Sources

- `.github/workflows/update-font-lock.yml:45` — current reusable Validation call and publication dependency.
- `.github/workflows/update-harness-plugin-lock.yml:58` — current Validation call; the separate drift report starts at line 95.
- `.github/workflows/update-personal-app-lock.yml:52` — current Validation call and GITHUB_TOKEN trigger note.
- `.github/workflows/test.yml:4` — ordinary and reusable Test entry points.
- [Font update failure](https://github.com/hyperlapse122/dotfiles/actions/runs/42659712101) — HTTP 500 while downloading a pinned font archive.
- [Harness plugin update failure](https://github.com/hyperlapse122/dotfiles/actions/runs/42659086260) — application download HTTP 500 and native application timeout.

---

## Planning Contract

### Approach

Delete the updater-only reusable Validation jobs and make each publish job depend only on resolve.
Keep the shared Test workflow and its manual/reusable candidate interfaces intact.
This is a small workflow policy change with two sequential implementation units and one PR.

### Key Technical Decisions

- KTD1. **Change updater job dependencies in place.** Remove each `validate` job, including the obsolete personal-app validation comment, and use `needs: resolve` for publication; keep artifact selection and narrow write permissions unchanged. Implements R1 and R3. (session-settled: user-directed — chosen over retaining or replacing candidate validation: the owner chose publication after generation.)
- KTD2. **Update the existing workflow contract tests.** Replace the obsolete font-only publication expectation with the direct-publication policy across all three updaters, while retaining reusable font candidate coverage separately. This catches accidental restoration of the gate without changing ordinary CI coverage.
- KTD3. **Correct current operational documentation.** Update the font and Pi guides and the development/testing guide rather than rewriting historical plans.

---

## Implementation Units

### U1. Remove the three updater Validation gates

- **Goal:** Implement R1, R3, R4, R5, and R6 through the existing generation/publication flow.
- **Files:** `.github/workflows/update-font-lock.yml`, `.github/workflows/update-harness-plugin-lock.yml`, `.github/workflows/update-personal-app-lock.yml`, `tests/test_ci_areas.py`, `tests/test_synthetic_model_lock.py`.
- **Approach:** Apply KTD1 and KTD2; rename the Synthetic publication test so it no longer claims prepublication validation.
- **Execution note:** Update the existing policy regression test; use local workflow checks rather than dispatching workflows that publish real pins.
- **Test scenarios:**
  - Covers AE1. Each updater publishes after resolve without a shared Test call or a Validation dependency.
  - Covers AE2 and AE3. Existing publication scripts retain generated-file-only staging, no-change exits, and normal error propagation.
  - Covers AE4. The reusable candidate selection and ordinary Test triggers remain intact.
  - Covers AE5. The harness drift report retains its resolve/publish dependencies and independent failure behavior.
- **Test seam:** Existing workflow text contracts catch repository wiring changes; they do not execute GitHub's scheduler or publish real candidates.
- **Verification:** Focused CI and Synthetic model tests pass; inspection confirms no changes to resolve, publication commands, shared Test, or drift-report behavior except the specified dependency.

### U2. Document direct automatic publication

- **Goal:** Explain R1 and R2 with the existing behavior retained by R3–R6.
- **Files:** `docs/guides/fonts.md`, `docs/guides/pi.md`, `docs/maintenance/development-and-testing.md`.
- **Depends on:** U1.
- **Approach:** Apply KTD3, document the lack of automatic push CI for bot publication, and state that defects are handled separately.
- **Test expectation:** None — documentation changes only; check for obsolete claims in current guides.
- **Verification:** Current guides describe generation followed by publication and distinguish ordinary/manual Test from automatic pin updates.

---

## Verification Contract

- Run the existing CI area, CI workflow, and Synthetic model test modules through unittest with the repository mise environment.
- Validate the complete test ownership map using `scripts/run-test-area.py --validate-only`.
- Inspect the final workflow diff for unchanged artifact IDs, base SHA selection, publication file scopes, no-change behavior, write permissions, and shared-skill reporting.
- Search current guides for stale statements that automatic updaters invoke Test or await validation.
- Observe the PR's hosted CI at its pushed head; do not manually dispatch update workflows or apply personal configuration for this change.

---

## Definition of Done

- Both implementation units are complete and the focused verification passes.
- Review finds no unresolved defect that prevents the agreed publication policy.
- Changes and this plan are committed, pushed, and available in one open PR.
- The handoff reports the PR's observed CI state and any remaining findings without claiming that automatic update publication was executed locally.
