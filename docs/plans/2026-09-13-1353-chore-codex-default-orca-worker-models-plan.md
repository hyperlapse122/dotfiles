---
title: Codex default and Orca worker models - Plan
type: chore
date: 2026-09-13
topic: codex-default-orca-worker-models
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Codex default and Orca worker models - Plan

## Goal Capsule

- Objective: The operator gets the chosen Codex model for direct sessions and for cross-model or cross-harness work delegated through Orca.
- Product authority: The user's requested model split and clarification that the worker exception applies to launches from other agents.
- Open blockers: None.

## Product Contract

### Summary

Separate the normal Codex default from the model selected when another agent launches Codex through Orca for cross-model or cross-harness work.
The requirements below define the two model and effort pairs and the boundary between them.

### Key Decisions

- **Scope the exception by launch purpose.** Governs R1, R2, R3. The user's clarification limits the exception to cross-model or cross-harness work launched from other agents.

### Problem Frame

Codex currently uses one managed model pair for normal sessions and launches that inherit its default.
Changing that pair alone would also change delegated workers that the operator wants to retain on Luna.

### Actors

- A1. The operator starts a normal Codex session.
- A2. A coordinating agent launches a Codex worker through Orca for cross-model or cross-harness work.

### Requirements

- R1. The managed Codex default MUST be `gpt-6-astra` with `medium` reasoning effort.
- R2. When another agent launches Codex through Orca for cross-model or cross-harness work, the launch MUST explicitly select `gpt-5.6-luna` with `max` reasoning effort.
- R3. Being inside Orca alone MUST NOT trigger R2; the launch must meet its delegation and work-purpose conditions.
- R4. The model split MUST preserve existing recipient selection, implementation fallback, and escalation rules, applying R2 when those rules select Codex for qualifying work.

### Acceptance Examples

- AE1. Covers R1, R3. The operator starts a fresh Codex session with no explicit model override, including a normal session opened in Orca. Its default is Astra/medium.
- AE2. Covers R2. A Claude or Antigravity coordinator launches Codex through Orca for a cross-harness review. The worker uses Luna/max even though the normal Codex default is Astra/medium.
- AE3. Covers R2. A Codex coordinator launches another Codex instance through Orca as a cross-model participant. The worker uses Luna/max; a different harness is not required.
- AE4. Covers R3, R4. A launch does not meet R2. This change adds no worker override for it, and existing explicit model-selection rules still apply.
- AE5. Covers R2, R4. Existing implementation routing selects the Codex fallback for qualifying delegated work. It retains Luna/max after the normal default changes.

### Scope Boundaries

- This is a model-selection policy change, with no new orchestration lifecycle or multi-step user flow.
- Other harnesses' model defaults and existing review participation rules are outside scope.
- This plan does not change a running session's model or remove the operator's ability to choose a model explicitly.
- Implementation belongs in the managed checkout source. Deployment to the live home directory requires a separate user request under `AGENTS.md`.

### Sources

- `.chezmoidata/agents.yaml` declares the current Codex default as Luna/max.
- `.chezmoitemplates/orchestration-coordinator.tmpl` owns the coordinator routing policy and already names Luna/max for the Codex implementation fallback.
- `.ci/test-codex-settings-reconcile.sh` checks the managed model and effort pair; `.ci/test-agent-instructions.sh` checks the orchestration instructions.
- The installed Orca orchestration guide, retrieved through `orca-ide skills get orchestration --reference references/coordinator-loop.md`, documents explicit launch model and effort selection and requested-versus-effective launch receipts.

## Planning Contract

### Key Technical Decisions

- KTD1. Change the existing `agents.codex.settings` model and effort leaves for R1. Reuse the per-key reconciler and update its paired assertions.
- KTD2. Put the R2/R3 rule in `.chezmoitemplates/orchestration-everyone.tmpl` so every supported coordinating harness receives it. Qualify the coordinator's name-only instruction to permit this model selection without changing recipient selection, fallback, or escalation under R4.
- KTD3. Check Orca's effective model and effort before claiming a qualifying launch used the requested pair. Render tests prove instruction delivery, not future agent compliance.

### Constraints

All changes belong in the managed source checkout.
Verification must use the isolated render contract in `AGENTS.md`, with a stub `op`, an empty configuration, a closed PATH, and a throwaway destination.
This work adds no public CLI flags or runtime APIs.

## Implementation Units

### U1. Separate the default and delegated model pairs

- Goal: Satisfy R1 through R4 and AE1 through AE5.
- Dependencies: None.
- Files: `.chezmoidata/agents.yaml`, `.chezmoitemplates/orchestration-everyone.tmpl`, `.chezmoitemplates/orchestration-coordinator.tmpl`, `.ci/test-codex-settings-reconcile.sh`, `.ci/test-agent-instructions.sh`.
- Approach: Apply KTD1 and KTD2 using the existing declarations and instruction payloads. Keep model selection separate from recipient selection.
- Patterns: Existing model-pair reconciliation checks and shared Everyone-payload assertions.
- Test scenarios: Assert the exact normal default; assert the qualifying worker pair and launch-purpose condition for every supported coordinator; assert the exclusion for mere Orca presence; preserve existing fallback and escalation assertions; check that the coordinator permits the required override.
- Verification: Run the existing isolated gates below and inspect a qualifying Orca launch receipt under KTD3.

## Verification Contract

- Use `.ci/lib/render-gate-helpers.sh` and the repository's isolated render setup. Never invoke real 1Password or deploy to the live home directory.
- Run `.ci/test-codex-settings-reconcile.sh` with its required isolated rendered settings script.
- Run `.ci/test-agent-instructions.sh` and `.ci/test-orchestration-hook.sh` to check shared instruction delivery and hook behavior.
- Confirm a qualifying Orca launch reports `gpt-5.6-luna` and `max` in its effective fields, not only its requested fields.
- Run `git diff --check` and require both repository CI workflows to finish green before merge.

## Definition of Done

- U1 satisfies R1 through R4 and AE1 through AE5 without broadening the model-selection exception.
- Required review findings are resolved and verification passes.
- The PR is merged after green CI and a mergeability check.
- The live home directory remains undeployed, and no secrets or temporary artifacts enter the commit.
