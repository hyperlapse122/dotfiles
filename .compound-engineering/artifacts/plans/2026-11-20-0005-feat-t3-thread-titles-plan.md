---
title: T3 Code Thread Titles - Plan
type: feat
date: 2026-11-20
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# T3 Code Thread Titles - Plan

## Goal Capsule

- **Objective:** Make generated T3 Code thread titles easy to scan by naming the work like a Conventional Commit subject.
- **Means:** Manage the native T3 Code text generation settings through Home Manager (KTD1, KTD2).
- **Authority:** The Product Contract governs behavior; the Planning Contract governs implementation. Stop if the pinned release cannot route review guides to Claude Code independently.
- **Delivery:** One pull request. The implementation workflow verifies and ships the change; host activation is separate.

## Product Contract

### Summary

Use OpenCode's Haiku as the shared text generation model, apply a Conventional Commit style to thread titles, and route review guides to Claude Code's Haiku.

### Problem Frame

The current title rule lives in local T3 Code state, so another installation does not inherit it. T3 Code uses the shared text model for several tasks, but generating a review guide also requires a provider that can inspect a checkout.

### Requirements

**Thread titles**

- R1. Use OpenCode `anthropic/claude-haiku-5-5` with the `low` variant as the default title model.
- R2. Ask for a single Conventional Commit-style subject, `type(scope): description` or `type: description`, for both new and regenerated titles. Use a lowercase type and a short imperative description of the thread's goal. Regeneration should fix the format even if the previous title names the right subject.

**Other generated text**

- R3. Use the shared selection from R1 for source control writing and voice transcript cleanup unless the user has set a task-specific override.
- R4. Use Claude Code `claude-haiku-5-5` for review guides without changing whether the feature is enabled.

### Scope Boundaries

- Preserve project overrides, existing thread titles, and unrelated settings. Do not add managed source control or transcript model overrides.

### Key Decisions

- **Use Haiku at low effort.** Governs R1. (session-settled: user-approved — chosen over the catalog's high default: a short title does not need to start at high effort.)
- **Share Haiku across text-only tasks.** Governs R3. (session-settled: user-directed — chosen over pinning Luna for non-title tasks: use the same new default without adding task-specific settings.)
- **Use Claude Code for review guides.** Governs R4. (session-settled: user-directed — chosen over leaving guides on the shared model or pinning Codex Luna: keep Haiku on a provider that can inspect the checkout.)

## Planning Contract

### Key Technical Decisions

- KTD1. **Use the native title settings.** Own `textGenerationModelSelection` as a whole object, with the OpenCode instance and its `variant` option. Declare `threadTitleInstructions` as a server setting, not an agent instruction or source control writing preference. The [pinned title prompt](https://github.com/pingdotgg/t3code/blob/v0.1.9/packages/provider-core/src/server/textGenerationPrompts.ts) appends this setting for both generation paths; keep the built-in response schema and other editorial rules. The [OpenCode adapter](https://github.com/pingdotgg/t3code/blob/v0.1.9/packages/provider-opencode/src/server/v2/textGeneration.ts) forwards the variant.
- KTD2. **Own only the review guide exception.** Set `reviewGuideModelSelection` to the `claudeAgent` instance and leave its effort at the native default. The [pinned settings resolver](https://github.com/pingdotgg/t3code/blob/v0.1.9/packages/shared/src/serverSettings.ts) otherwise resolves guides through the source control model, which inherits the shared selection when no explicit writer is set. The OpenCode adapter rejects read-only checkout investigation; the [Claude Code adapter](https://github.com/pingdotgg/t3code/blob/v0.1.9/apps/server/src/textGeneration/ClaudeTextGeneration.ts) supports it.

### Risks & Dependencies

The instruction guides model output; it does not validate the format or override native fallbacks. Runtime generation requires a usable Anthropic route in the T3 OpenCode instance.

## Implementation Units

### U1. Declare the title model and rule

- **Goal:** Apply the shared Haiku model, title rule, and guide exception.
- **Requirements:** R1–R4.
- **Dependencies:** None.
- **Files:** `home/h82/t3code.nix`, `tests/t3code-traits.nix`, `tests/t3code-launch.py`, `docs/agent-routing.md`.
- **Approach:** Extend the existing activation settings and model ownership declarations per KTD1 and KTD2. Update the routing reference. Keep the changed settings contract in the traits check, not duplicated in the launch check.
- **Patterns to follow:** The module's existing whole model selections and the traits check's scratch-home activation exercise.
- **Test scenarios:** Activate from a scratch home with old text and review guide models, stale options and title instructions, and a project override. Expect the declared rule and selections without stale options. Check that activation leaves existing source control and transcript selections untouched rather than owning them or enabling review guides.
- **Verification:** The traits check verifies settings written by activation. It does not verify that a signed-in model follows the prompt.

## Verification Contract

Run `nix build --no-link .#checks.x86_64-linux.t3code-traits` and the affected `agent-instructions` check for the routing document on a supported builder. If Linux cannot build locally, check the evaluated settings inputs on macOS and report both Linux builds separately as deferred to CI.

## Definition of Done

U1 and the affected checks cover the managed settings change. The diff contains only the settings, their coverage, and documentation; no host settings, thread data, or experimental code are changed directly.
