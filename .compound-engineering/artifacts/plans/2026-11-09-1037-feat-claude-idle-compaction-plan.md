---
title: Claude Idle Compaction - Plan
type: feat
date: 2026-11-09
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Claude Idle Compaction - Plan

## Goal Capsule

- **Objective:** The owner can reproduce the selected Claude idle-compaction preference on existing and new machines.
- **Means:** Extend the existing Claude provider reconciliation (KTD1).
- **Authority:** The Product Contract owns behavior; the Planning Contract owns implementation choices.
- **Execution profile:** One unit and one PR; LFG owns implementation, review, and shipping.
- **Stop conditions:** A conflict with a settled decision or failed required verification blocks shipping.
- **Open blockers:** None.

## Product Contract

### Summary

Manage Claude Code's selected `Compact idle threads` preference through explicit dotfiles application.

### Problem Frame

The owner's current Claude idle-compaction choice is local and cannot yet be reproduced by the repository on another machine.

### Key Decisions

- **Retain the current Claude mode.** Governs R1. (session-settled: user-directed — chosen over `onReturn`, `off`, and `default`: reproduce the current `Before the cache expires (beta)` selection.)
- **Manage only the existing Claude instance.** Governs R2. (session-settled: user-approved — chosen over changing the global default: preserve other providers and local defaults.)

### Requirements

- R1. Explicit chezmoi application sets the existing `claudeAgent` provider's idle-compaction mode to `beforeCacheExpires` in fresh and existing homes.
- R2. Preserve the global idle-compaction fields, additional provider instances, and unrelated Claude settings under the existing ownership rules.
- R3. Reapplication restores the selected value after local edits and produces no further changes once it converges.
- R4. Worktree bootstrap remains read-only for personal configuration.

### Scope Boundaries

No T3 application changes, global compaction changes, management of additional Claude instances, or application to the owner's actual home are included.
No new configuration abstraction or validation mechanism is needed for this fixed preference.

## Planning Contract

### Key Technical Decisions

- KTD1. **Extend the existing provider config merge.** Set `idleCompaction` alongside the existing Claude `enabled` and `binaryPath` assignments in `home/.chezmoitemplates/t3-code-settings` to implement R1–R3. Provider configuration is already owned there; a generic provider preference map would add machinery for one fixed value.
- KTD2. **Use existing disposable-home fixtures.** Extend `tests/test_t3_code_settings.py` to prove R1–R3 without applying the real home. The fixture runs actual chezmoi transforms; it does not prove T3's compaction scheduling.

### Grounding

The Claude template already validates and merges its existing config object.
`expected_claude`, the fresh-home tests, and the platform render tests share an expected provider shape.
`test_native_claude_reconciles_executable_and_preserves_custom_scope` exercises custom Claude settings and repeated apply.
`test_declared_preferences_converge_without_losing_unowned_values` already preserves the global `idleCompaction` value.
The provider field and enum are defined in the [official T3 settings contract](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/settings.ts).

## Implementation Units

### U1. Reconcile Claude idle compaction

**Goal:** Implement R1–R4 using KTD1 and KTD2.

**Dependencies:** None.

**Files:** `home/.chezmoitemplates/t3-code-settings`, `tests/test_t3_code_settings.py`, `docs/guides/t3-code.md`.

**Approach:**

1. Add the fixed mode to the existing Claude config assignments.
2. Update the shared expected Claude shape and extend existing preservation coverage with an initially different mode, global settings, and an additional Claude instance.
3. Document the new owned provider preference and clarify that the global idle-compaction default remains local.

**Patterns to follow:** Existing config merge and custom-scope preservation tests in the files above.

**Test scenarios:**

1. A missing settings file produces the selected Claude mode; reuse the existing fresh-home and supported-platform render cases.
2. An existing Claude mode of `off` is restored while custom Claude fields, global `idleCompaction`, legacy `compactIdleThreads`, and another Claude instance remain unchanged.
3. Editing the managed mode after apply is corrected on the next apply; a subsequent apply is byte-stable.
4. Existing invalid-object tests continue to fail safely without replacing the destination file.

**Verification:** The fixture proves the selected provider value and preservation on repeat apply. Existing platform rendering covers Windows, Ubuntu, and macOS template selection.

## Verification Contract

- Run `mise exec -- python -m unittest discover -s tests -p test_t3_code_settings.py` for actual chezmoi application in disposable homes and cross-platform rendering.
- Run `git diff --check` for patch integrity.
- Inspect the diff to confirm no bootstrap or personal-application changes and no unrelated files.
- Native compaction scheduling and browser tests are unnecessary because this change only manages an existing supported setting.

## Definition of Done

U1 satisfies R1–R4, all required checks pass, and the guide reflects the new ownership boundary.
The PR contains only this work and its plan, with no experimental code or unrelated bootstrap changes.
