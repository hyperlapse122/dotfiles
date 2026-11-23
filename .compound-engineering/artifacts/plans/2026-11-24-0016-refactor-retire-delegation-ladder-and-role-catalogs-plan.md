---
title: Retire the Delegation Ladder and Role Catalogs - Plan
type: refactor
date: 2026-11-24
topic: retire-delegation-ladder-and-role-catalogs
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Retire the Delegation Ladder and Role Catalogs - Plan

## Goal Capsule

- **Objective.** The owner can delegate work using Compound Engineering (CE) and harness defaults, and update each harness independently of its built-in roles.
- **Product authority.** This plan covers dotfiles' delegation instructions, role catalogs, the extra dotfiles requirement to obtain approval for external reviews, and guidance derived from the retired ladder.
- **Means.** Remove the local selection and pre-send instructions, retire their catalogs and simplify the release updaters in one PR.
- **Open blockers.** None.

---

## Product Contract

### Summary

Retire the dotfiles rule that asks `decide` to select a subagent role. Remove the Claude Code, Codex, and Pi role catalogs and the work required to keep them in sync with releases. Preserve historical measurements with their original context.

### Problem Frame

The model and effort ladder was retired in commit `0076c3b`. A separate rule still asks `decide` to choose among eligible roles. The release updater still requires role extraction to succeed before it accepts a new harness version. Two benchmark reports also describe ladder settings in the present tense. [Role selection rule](https://github.com/hyperlapse122/dotfiles/blob/0076c3b/home/h82/agents/instructions/task-guide.md#decide-for-subagent-roles) · [Release updater](../../../.github/workflows/update-dependencies.yml) · [Child effort benchmark](../solutions/best-practices/codex-child-give-up-rate-by-reasoning-effort.md) · [Implementation worker benchmark](../solutions/best-practices/codex-implementation-worker-tier-on-investigation-units.md)

### Requirements

**Delegation in standalone and T3 sessions**

- R1. Honor an explicit user choice of role, model, or reasoning effort. For each unspecified choice, follow the CE workflow and the harness defaults.
- R2. Remove the dotfiles role-selection procedure, including its task-guide trigger and its instruction to call `decide` when multiple roles qualify. Managed guidance and checks must no longer prescribe that procedure.
- R3. Keep the retired model and effort ladder, provider preference order, delegation quota preflight, and automatic provider substitution out of active dotfiles guidance.

**Role catalogs and harness releases**

- R4. Retire the repository's built-in role snapshots for Claude Code, Codex, and Pi, their extraction tools, and their catalog-specific checks. Stop distributing the Claude Code snapshot in the managed home.
- R5. Each harness release can advance its version pin without generating, comparing, or committing a role catalog. Remove the catalog-specific work from scheduled updates.

**Historical guidance**

- R6. Keep benchmark results and measurement conditions intact. Describe ladder-based selections as decisions made for those experiments wherever a reader could mistake them for current instructions.

**External reviews**

- R7. Rely on the CE and harness review controls. Retire the extra dotfiles rule requiring advance disclosure and approval of review material and recipients, including its OpenCode and `decide` instructions. Keep protections for secrets and stored data.

### Key Decisions

- **Delegate role selection to CE and the harness.** Governs R1–R3. (session-settled: user-directed — chosen over retiring only the model ladder: the owner also wants role selection to follow the workflow and harness defaults.)
- **Retire the release catalogs in full.** Governs R4–R5. (session-settled: user-directed — chosen over keeping repository-only snapshots: the owner also wants to end the work of refreshing those lists.)

### Acceptance Examples

- AE1. A CE workflow can use two eligible roles and the user gives no preference. Delegation proceeds through the workflow's normal selector without consulting `decide`, including when its backend is unavailable. Covers R1–R3.
- AE2. The user requests a supported role and leaves model and effort unspecified. The requested role runs with the model and effort selected by CE or the harness. Covers R1.
- AE3. A new Claude Code, Codex, or Pi release changes its built-in roles. The scheduled updater can record the new version without running an extractor or expecting a role-list diff. A fresh managed home receives no dotfiles role snapshot. Covers R4–R5.
- AE4. A reader opening either effort benchmark can recover the measured settings and outcomes and can tell that the recorded model choice applied at the time of the experiment. Covers R6.
- AE5. A configured peer is available for a review. No dotfiles instruction asks the owner to approve the material or recipients again. CE owns its configured peer allowlist and route selection. Explicit user restrictions on data and recipients still apply. Covers R7.

<!-- ce-section: work-relationships -->

### How This Work Fits Together

This plan retires dotfiles' role selection and the catalogs that supported it. The harnesses continue to provide subagents, including Pi's managed subagent extension. CI failure triage was handled separately. PR #301 removed its required `decide` call while this change was in review. [Issue #300](https://github.com/hyperlapse122/dotfiles/issues/300) · [PR #301](https://github.com/hyperlapse122/dotfiles/pull/301)

---

## Planning Contract

**Product Contract preservation.** R1–R6 and AE1–AE4 retain the agreed behavior. R7 and AE5 incorporate the owner's subsequent request to remove the local pre-send approval instructions.

### Key Technical Decisions

- KTD1. Remove the role-selection section from the shared guide and its trigger from the native template. Use the existing CE and harness delegation rules. Covers R1–R3. (session-settled: user-directed — chosen over retiring only the model ladder: the owner also wants role selection to follow workflow and harness defaults.)
- KTD2. Remove all three catalogs and release only the harness pins. Drop Codex's source fetch used by its roster extractor. Keep Pi's source pin because its package builds from source. Covers R4–R5. (session-settled: user-directed — chosen over keeping repository-only snapshots: the owner also wants to end their maintenance.)
- KTD3. Remove the repository-specific review approval procedure from repository, native, and T3 instructions. Preserve CE peer configuration, the T3 isolation exception and its coverage report, and the CI triage behavior delivered separately for issue #300. Covers R7.

---

## Implementation Units

### U1. Use the configured delegation and review defaults

Update the root instructions, shared template, task and T3 guides, routing docs, repository reference, and their render checks. Remove the OpenCode guide trigger together with its section. Point historical catalog links at the revision that carried the snapshots. Regenerate the native instruction receipts from the rendered output. Remove checks dedicated to the retired procedures and verify the remaining instructions still reach each harness. Date the two benchmark conclusions and their obsolete action items, preserving measured data and generally applicable findings. Covers R1–R3, R6–R7.

### U2. Retire the catalogs and their distribution

Remove role snapshots, extraction commands, public flake outputs, their Python and Nix checks, and the managed Claude Code catalog link. Preserve the Pi subagent extension, model lists, and unrelated Home Manager files. Remove Codex's catalog-only source metadata from its release manifest and updater while preserving all binary asset verification. Covers R4.

### U3. Decouple release updates from role extraction

Use the existing release steps to update Claude Code, Codex and Pi pins independently. A failed release lookup must still report its cause, restore that pin, and allow other updates. Update the reconciliation fixtures and commit assertions to cover single-pin bumps without catalogs. Covers R5.

---

## Verification Contract

- Exercise the native and T3 render paths using fixture homes. Verify delivered instructions, retained CI triage and secret protections, and the absence of the retired role-selection and advance-approval rules.
- Exercise all three version updates in the maintenance workflow fixture, covering success, partial release failures, and single-pin commits. Run the Codex release tests for supported platforms and invalid assets. Confirm the packaged Pi still has its source pin.
- Run the project check, validate relevant Nix outputs on supported builders, and check historical wording against the original benchmark measurements.

---

## Definition of Done

The managed harnesses delegate using R1–R3 and R7. All three harnesses update in the catalog-free fixture, the flake no longer publishes role extractors, and the benchmark reports describe the retired policy in the past tense. The PR reports verification and tracks CI triage separately under issue #300.
