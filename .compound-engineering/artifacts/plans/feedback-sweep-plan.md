---
title: Remove CI event admission and record local CE verification
date: 2026-11-07
topic: feedback-sweep
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-sweep
---

## Goal Capsule

- Objective: Contributors receive actual validation results without the redundant skipped Validate check, and Antigravity completion has local authenticated evidence.
- Means: Remove Test events and use direct Test triggers (KTD1).
- Authority: Current user instructions, Product Contract, repository instructions, then Planning Contract.
- Execution profile: One PR; implement, verify, review and publish autonomously. Merging remains with the user.
- Stop conditions: Personal configuration application, credential exposure, cancellation of unrelated runs, or lost validation coverage.

## Human Notes

<!-- human-notes:start -->
<!-- Everything between these markers is human-owned. The reconciler never reads or writes inside this region. Add your own context, priorities, and decisions here. -->
<!-- human-notes:end -->

## Product Contract

### Summary

Delete the event-admission workflow and its unused policy. Let Test handle push and pull_request directly, preserving its manual and reusable interfaces. Record the successful local Antigravity invocation and the local-only verification policy.

### Problem Frame

The admission workflow suppresses duplicate suites but leaves a skipped Validate reusable-call check. Its metadata lookups and conditional scheduling add complexity. Antigravity documentation still requires cross-platform authenticated evidence the user has now scoped to the local PC.

### Key Decisions

- Remove Test events (session-settled: user-directed — chosen over retaining admission or adding dispatch permissions: the user explicitly selected workflow removal). Governs R18.
- Verify authenticated Antigravity locally only (session-settled: user-directed — chosen over hosted authenticated inference: the user does not want paid Actions model calls). Governs R9.

### Requirements

- **R9** — Record actual authenticated local-PC invocation of the pinned Antigravity CE skill. Keep hosted smoke credential-free and make no claim of authenticated disposable-home or other-platform completion. Source: https://github.com/hyperlapse122/dotfiles/issues/52.
- **R18** — Remove `.github/workflows/test-events.yml` and unused admission code. Test directly handles all pushes and pull requests, retains manual/reusable callers and immutable candidate input selection, and uses read-only permissions without cancellation. Preserve branch, default-branch, tag and fork coverage. Same-repository PR branches may run both push and merge-result suites; deduplication and superseded-head suppression are deliberately retired with admission. Source: https://github.com/hyperlapse122/dotfiles/issues/90.

Product Contract changed: R9 — local-only scope selected by user; R18 — remove admission and retire its deduplication while retaining event coverage.

### Sources / Research

- `.github/workflows/test.yml`: existing test matrices, workflow_call/workflow_dispatch inputs, immutable `${{ inputs.base-sha || github.sha }}` checkout.
- `tests/test_ci_areas.py` and `scripts/run-test-area.py`: workflow contracts and complete unittest ownership.
- `tests/smoke_antigravity.py`: existing full-skill-read and successful-response verifier.
- Local verification on 2026-11-07: macOS ARM64, agy 1.5.2, CE 3.35.1; full native skill read (45 lines, 4048 bytes) and exact successful response. Existing native profile in a disposable working directory; credentials not copied.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Add unfiltered push and pull_request triggers directly to Test and remove the entire admission workflow/policy. Keep all Test jobs and caller inputs unchanged. This removes the declaration producing skipped Validate and keeps conflicted/no-PR branch validation without PR metadata dependence. Governs R18.
- KTD2. Replace admission unit tests with direct-workflow contract coverage and update the test-area ownership manifest together. Keep existing candidate-lock validation tests. Governs R18.
- KTD3. Update guides to record local native authenticated evidence, distinguish it from isolated credential-free capture, and keep API-key smoke explicitly opt-in and local. No paid model calls or credentials in Actions. Governs R9.

---

## Implementation Units

### U1. Remove CI admission and retain direct event coverage

- Requirements: R18. Dependencies: none.
- Files: `.github/workflows/test-events.yml`, `.github/workflows/test.yml`, `scripts/ci-event-policy.py`, `tests/test_ci_event_policy.py`, `tests/test_ci_workflows.py`, `scripts/run-test-area.py`.
- Approach: Remove obsolete workflow, policy and decision tests; add direct trigger contracts in the replacement module. Preserve existing matrix/job bodies, input schemas and read-only permissions.
- Test scenarios: Direct unfiltered push and pull_request; workflow_dispatch/workflow_call inputs preserved; immutable candidate checkouts and artifact selection preserved; no admission dependency, conditional reusable wrapper, write permission or cancellation; complete test ownership after module replacement.
- Verification: Focused CI workflow/area tests, area ownership validation, workflow syntax lint, and hosted push/PR checks on the published head.

### U2. Document direct CI and local Antigravity verification

- Requirements: R9, R18. Dependencies: U1.
- Files: `docs/maintenance/development-and-testing.md`, `docs/guides/harness-plugins.md`, `docs/maintenance/chezmoi-source.md`.
- Approach: Replace the admission/scheduling-limitation section with direct event semantics and duplicate-suite cost. Update check-name guidance without rewriting historical measurements. Replace outdated Antigravity deferral/cross-platform completion criteria with the user-selected local policy and observed evidence.
- Test scenarios: Documentation reflects direct Test jobs and no skipped wrapper; local authenticated result is distinguished from disposable-home capture and does not claim other-platform proof.
- Verification: Diff/source reference review and whitespace checks; local authenticated verifier already passed this run. Do not repeat paid inference for editorial changes.

---

## Verification Contract

Run focused `test_ci_workflows` and `test_ci_areas` discovery, complete area ownership validation, then the build-contracts area and available actionlint. Preserve candidate-lock contract coverage. Review the exact branch diff before push; record actual hosted push/PR run URLs and outcomes. Browser tests have no affected application routes.

## Definition of Done

Direct event coverage and existing callers remain intact; obsolete admission artifacts are removed; tests and ownership validation pass; local-only authenticated evidence is documented accurately; reviewed changes are committed and pushed in an open PR. No abandoned scheduling experiments, paid Actions inference, personal apply, or fabricated validation success.
