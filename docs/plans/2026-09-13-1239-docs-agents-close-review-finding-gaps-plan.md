---
title: Close the gaps that let a review finding go unapplied (Issue 404) - Plan
type: docs
date: 2026-09-13
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/404
---

# Close the gaps that let a review finding go unapplied (Issue 404) - Plan

## Goal Capsule

- **Objective:** Settle and encode the four review finding apply/deferral rules into `.chezmoitemplates/agents-instructions.tmpl` and assert them in `.ci/test-agent-instructions.sh` to cleanly and completely resolve GitHub issue #404.
- **Means:** Update line 118 of `.chezmoitemplates/agents-instructions.tmpl` to address all four gaps identified in issue #404:
  1. Specify both apply paths: explicit reviewer apply authority (`apply:local`) or caller-side apply when review runs report-only (e.g. `mode:agent` in `lfg`).
  2. Clarify that the user-scoped instruction outranks a skill's internal threshold: every actionable finding must be applied in-run, explicitly including single-reviewer anchor-75 findings.
  3. Establish a sharp branch-scope test: a finding whose fix touches only files the branch already changes is in scope by default, and deferring it requires a stated blocker or product/design decision, never a bare claim of being adjacent or pre-existing.
  4. Preserve and reinforce the rule that a deferred finding must be filed as a tracker issue, and that an unapplied findings section is a working note that must be resolved (with issue links or applied fixes) and deleted before run end.
  5. Add needle assertions in `.ci/test-agent-instructions.sh` to guard the new rules against regressions.
- **Authority:** Issue #404 acceptance criteria and repo instructions supplement `AGENTS.md`.
- **Execution profile:** Documentation template updates and CI test needle additions. Verification via `.ci/test-agent-instructions.sh`.
- **Stop conditions:** Stop and report if `.ci/test-agent-instructions.sh` fails or if any banned needles conflict.
- **Tail ownership:** The pipeline caller (`lfg`) owns commit, push, PR creation, CI babysitting, and merging.

---

## Product Contract

### Summary

GitHub issue #404 identified four concrete gaps in `.chezmoitemplates/agents-instructions.tmpl` that allowed review findings to be deferred during PR #392 rather than applied in-run:
1. Prescribed apply mechanism (`apply:local`) is unreachable inside `lfg` where `mode:agent` enforces report-only review.
2. Disagreement between `lfg` step 5's confidence bar (100, or 75 with cross-persona agreement) and the template's instruction that every actionable finding must be fixed in-run.
3. Overly broad interpretation of "outside the scope of the branch" used to defer changes in files the branch already touches.
4. Use of the PR unapplied-findings checklist as a substitute for filed tracker issues.

### Requirements

- R1. The `apply:local` prescription is expanded to recognize caller-side apply when review is report-only (such as `mode:agent` in pipeline runs).
- R2. The instruction explicitly states that this user-scoped obligation wins over a skill's internal apply threshold: every actionable finding must be applied in-run, explicitly including single-reviewer anchor-75 findings.
- R3. The instruction provides a sharp test for branch scope: a finding whose fix touches only files the branch already changes is in scope by default; deferring it requires a stated blocker or product/design decision, never a bare claim of being adjacent or pre-existing.
- R4. The instruction reaffirms that a deferred finding must be filed in the tracker, and an unapplied findings checklist is a working note that cannot survive delivery.
- R5. `.ci/test-agent-instructions.sh` is updated with positive needles covering the new rules, and all instruction tests pass.
- R6. Issue #404 is referenced and closed upon PR merge.

---

## Planning Contract

- Risk: Line 118 of `.chezmoitemplates/agents-instructions.tmpl` is an unwrapped line that composes into `~/.claude/CLAUDE.md`, `~/.gemini/AGENTS.md`, and `~/.codex/AGENTS.md`. Edits must maintain ASD-STE100 clear and concise language, avoid triggering banned phrases, and preserve all existing needle substrings.
- Conventions: Keep line 118 as a single paragraph without breaking unwrapped format rules expected by `.ci/test-agent-instructions.sh`.

---

## Implementation Units

### Unit 1: Update `.chezmoitemplates/agents-instructions.tmpl`

- **Goal:** Update line 118 of `.chezmoitemplates/agents-instructions.tmpl` to clearly address all four gaps.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` (modify).
- **Details:**
  - Revise the apply mechanism sentence to state: "To fix findings in place, the run MUST either give the review explicit local apply authority (under `ce-code-review` that is the `apply:local` token, because a bare invocation is report-only and the deprecated `mode:autofix` token is ignored) or, when review runs report-only (such as `mode:agent` in an `lfg` pipeline run), apply the findings caller-side before proceeding."
  - Add the precedence and anchor-75 clause: "This obligation wins over a skill's internal apply threshold: every actionable finding (`gated_auto` or `manual` with a concrete mechanical fix) MUST be applied in-run, including a single-reviewer anchor-75 finding; a skill's narrower confidence bar or cross-persona requirement does not authorize deferral."
  - Sharpen the scope clause: "A finding whose fix touches only files the branch already changes is in scope by default; deferring it requires a stated blocker or product/design decision, never a bare claim of being adjacent or pre-existing. Only a fix that requires touching files outside the branch's changes qualifies for the out-of-scope deferral."
  - Preserve the existing tracker filing and working-note rules.
- **Acceptance:**
  - Clear and concise ASD-STE100 prose.
  - Addresses points 1, 2, 3, and 4 cleanly.

### Unit 2: Update `.ci/test-agent-instructions.sh` and verify

- **Goal:** Add needles asserting the new rules in `.ci/test-agent-instructions.sh` and verify all tests pass.
- **Files:** `.ci/test-agent-instructions.sh` (modify).
- **Details:**
  - Add needles for:
    - "apply the findings caller-side before proceeding"
    - "including a single-reviewer anchor-75 finding"
    - "touches only files the branch already changes is in scope by default"
  - Run `.ci/test-agent-instructions.sh`.
- **Acceptance:**
  - `.ci/test-agent-instructions.sh` passes without errors.

---

## Verification Contract

- Run `.ci/test-agent-instructions.sh` to confirm that all harnesses render the updated instructions correctly and all positive/banned needles pass.
- Verify git diff is clean and minimal.

---

## Definition of Done

1. Technical plan recorded in `docs/plans/`.
2. `.chezmoitemplates/agents-instructions.tmpl` updated.
3. `.ci/test-agent-instructions.sh` updated with needles.
4. Code review and simplification executed per LFG pipeline.
5. PR created, watched, and merged to close Issue #404.
