---
title: T3 PR and MR Watching - Plan
type: feat
date: 2026-11-16
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# T3 PR and MR Watching - Plan

## Goal Capsule

- Objective: Use the same babysitting workflow for GitHub PRs and GitLab MRs in T3 Code.
- Means: Extend the existing T3 instruction branch (KTD1).
- Authority: The confirmed conversation supplies product scope; repository instructions govern delivery.
- Execution profile: One implementation unit and one stacked PR targeting `feat/t3-wireframe-options` above PR #185.
- Completion owner: LFG implements, reviews, and publishes; the owner retains merge authority.
- Stop condition: Report evidence that invalidates a settled decision before changing that decision.

## Product Contract

### Summary

Route `ce-babysit-pr` monitoring through T3 Code's watcher for GitHub and GitLab, retaining forge CLIs for reads and mutations.

### Problem Frame

The skill's default watcher and GitHub-only helpers do not express the requested T3 workflow for GitLab merge requests.

### Requirements

- R1. Apply the additions only inside T3 Code sessions across the managed harnesses.
- R2. Use `watch_pull_request` for waits, follow its persistent-watch lifecycle, and release it with `unwatch_pull_request` when watching ends.
- R3. Allow `gh` for GitHub and `glab` for GitLab reads and mutations while replacing CLI watch loops with T3 wakeups.
- R4. Continue GitLab babysitting and its delegated feedback work through equivalent GitLab operations instead of stopping at GitHub-only gates or running GitHub-only helpers against GitLab.
- R5. Retain the skill's feedback-before-CI ordering, mutation authority, state-based readiness, and supported stack semantics under the forge-specific operations.

### Key Decisions

- **Replace monitoring only.** Governs R2, R3. (session-settled: user-directed — chosen over eliminating forge CLIs entirely: T3 supplies wakeups while CLIs still perform reads and mutations.)
- **Cover GitLab throughout the babysit flow.** Governs R4, R5. (session-settled: user-approved — chosen over replacing only the wait source: GitHub-only entry gates would otherwise stop GitLab work.)

### Scope Boundaries

The change is repository-managed instruction text and its existing delivery receipt. Upstream plugin files, new watcher implementations, and new forge adapters are outside this change.

## Planning Contract

### Key Technical Decisions

- KTD1. Add a T3 babysitting section to `home/h82/agents/instructions/instructions.md.tmpl` and mirror it in `docs/agent-routing.md`; the existing renderer already isolates T3 additions from CLI baselines.
- KTD3. For GitLab, require fresh forge reads and persistent feedback IDs and source revisions, with head-scoped CI and action marks and unresolved decisions across T3 wakes; pass that evidence and the GitLab override into delegated feedback work. This replaces the GitHub-only snapshot and review-helper path without adding scripts.
- KTD2. Update only the T3 content hash in `tests/agent-instructions.py`; its existing materialized-render coverage owns policy bytes and branch isolation.

### Assumptions

The instruction addition uses the T3 watcher contract exposed in this session. Live GitLab authentication and repository state remain execution inputs to a future babysit invocation.

## Implementation Units

### U1. Add T3 babysitting instructions

- **Goal:** Deliver R1-R5 through the existing instruction path.
- **Dependencies:** The parent branch's T3 visual instructions remain present.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `docs/agent-routing.md`, `tests/agent-instructions.py`.
- **Approach:** Add the section under the T3 branch per KTD1, with the GitLab state and delegation substitution from KTD3; retain the parent additions and refresh the receipt per KTD2.
- **Patterns to follow:** Adjacent T3 delegation and visual sections; the existing instruction check.
- **Test scenarios:** Render the T3 policy for the managed harnesses with the new section while baseline renders retain their existing receipts.
- **Verification:** The declared `agent-instructions` check succeeds with the updated T3 receipt. It proves instruction delivery, not signed-in forge behavior.

## Verification Contract

Use the existing `agent-instructions` check for U1. Apply the repository's pre-push formatting, Markdown lint, and relevant-check requirements. Required platform and full-CI evidence follow `AGENTS.md`.

## Definition of Done

U1 is implemented, its existing delivery check passes, review findings are assessed, and the stacked PR targets the requested parent branch. Remove abandoned edits and report pending CI or hardware evidence separately.
