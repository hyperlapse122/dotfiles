---
title: "Refactor OMP Subagents to Gemini 3.7 Flash - Plan"
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Refactor OMP Subagents to Gemini 3.7 Flash - Plan

## Goal Capsule

- **Objective:** Restrict Claude Opus 5 usage in omp to direct interactive roles (`default`, `slow`, `plan`), and remap all bundled subagents (`task`, `designer`, `reviewer`, `security-reviewer`, `scout`, `librarian`, `sonic`) and auxiliary roles (`advisor`, `commit`) to Gemini 3.7 Flash (`@smol`).
- **Product authority:** User-settled decision to minimize subscription token consumption and background latency while preserving high-tier reasoning for interactive turns.
- **Execution profile:** Data-only change in `.chezmoidata/agents.yaml` with accompanying documentation alignment in `AGENTS.md` and verification via `.ci/test-omp-agent-reconcile.sh` and `.ci/check-omp-agent-roster.sh`.
- **Stop conditions:** Do not modify `tiny` role (`gemini-3.1-flash-lite:minimal`), provider authentication env vars, or external model catalogs.
- **Open blockers:** None.

---

## Product Contract

### Summary

Proposes updating `.chezmoidata/agents.yaml` so that only user-interactive session turns (`default`, `slow`, `plan`) utilize `anthropic/claude-opus-5`, while all delegated subagents and auxiliary roles are routed to `google-antigravity/gemini-3.7-flash` via the `@smol` alias.

### Key Decisions

- KD1. **Interactive Session Ceiling Retention:** `modelRoles.default`, `modelRoles.slow`, and `modelRoles.plan` retain Claude Opus 5 (`anthropic/claude-opus-5:high` and `:max`), ensuring interactive reasoning capacity is preserved. Governs R1, R2. (session-settled: user-directed — chosen over switching all roles to Gemini Flash: user specified keeping Claude for direct interaction).
- KD2. **Subagent Consolidation on Gemini 3.7 Flash:** All seven bundled subagents in `task.agentModelOverrides` (`task`, `designer`, `reviewer`, `security-reviewer`, `scout`, `librarian`, `sonic`) and auxiliary `modelRoles` (`advisor`, `commit`) route to `@smol` (`google-antigravity/gemini-3.7-flash:high`). Governs R3, R4, R5. (session-settled: user-directed — chosen over keeping high-cost models for reviewer/security-reviewer: user directed all non-interactive roles to Gemini Flash).
- KD3. **Documentation Alignment:** `AGENTS.md` model placement narrative is updated to document the interactive-vs-subagent role boundary. Governs R6.

### Requirements

**Model Roles Alignment**
- R1. `agents.omp.settings.modelRoles.default` remains `anthropic/claude-opus-5:high` and `modelRoles.slow` remains `anthropic/claude-opus-5:max`.
- R2. `agents.omp.settings.modelRoles.plan` remains `@slow` (`anthropic/claude-opus-5:max`).
- R3. `agents.omp.settings.modelRoles.advisor` is set to `@smol` (`google-antigravity/gemini-3.7-flash:high`).
- R4. `agents.omp.settings.modelRoles.commit` remains `@smol`, `modelRoles.smol` remains `google-antigravity/gemini-3.7-flash:high`, and `modelRoles.tiny` remains `google-antigravity/gemini-3.1-flash-lite:minimal`.

**Subagent Override Mapping**
- R5. `agents.omp.settings.task.agentModelOverrides` maps every bundled agent (`designer`, `librarian`, `reviewer`, `scout`, `security-reviewer`, `sonic`, `task`) to `@smol`.

**Documentation and Testing**
- R6. `AGENTS.md` model placement section reflects that Claude Opus 5 is reserved for interactive session roles while subagents run exclusively on the light Gemini Flash tier.
- R7. Isolated test suites `.ci/test-omp-agent-reconcile.sh` and `.ci/check-omp-agent-roster.sh` pass cleanly with zero errors.

### Key Flows

- F1. **Direct Session Turn Execution:**
  - **Trigger:** User interacts directly with omp in standard mode, `/slow`, or `/plan`.
  - **Actors:** User, omp main session.
  - **Steps:** Session resolves `default`, `slow`, or `plan` role to Claude Opus 5.
  - **Outcome:** Interactive turn executes with Claude Opus 5 reasoning.
  - **Covered by:** R1, R2
- F2. **Delegated Subagent Dispatch:**
  - **Trigger:** Task tool or skill dispatches any subagent (`task`, `scout`, `reviewer`, `designer`, `security-reviewer`, `librarian`, `sonic`).
  - **Actors:** Parent agent, subagent worker.
  - **Steps:** omp checks `task.agentModelOverrides`, resolves the agent to `@smol`, and launches with `google-antigravity/gemini-3.7-flash:high`.
  - **Outcome:** Subagent executes on Gemini 3.7 Flash without consuming Anthropic quota.
  - **Covered by:** R3, R5

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R4.** Given the rendered settings, when inspecting `modelRoles`, then `default` is `anthropic/claude-opus-5:high`, `slow` is `anthropic/claude-opus-5:max`, `plan` is `@slow`, `advisor` is `@smol`, `commit` is `@smol`, `smol` is `google-antigravity/gemini-3.7-flash:high`, and `tiny` is `google-antigravity/gemini-3.1-flash-lite:minimal`.
- AE2. **Covers R5.** Given the rendered settings, when inspecting `task.agentModelOverrides`, then all keys (`designer`, `librarian`, `reviewer`, `scout`, `security-reviewer`, `sonic`, `task`) have value `@smol`.
- AE3. **Covers R7.** Given `.ci/test-omp-agent-reconcile.sh` and `.ci/check-omp-agent-roster.sh` run against rendered settings, then both exit with status code 0.

### Scope Boundaries

- **In scope:** Updating `modelRoles.advisor` and `task.agentModelOverrides` in `.chezmoidata/agents.yaml`; updating `AGENTS.md` text; running CI verification scripts.
- **Out of scope:** Modifying `tiny` role, altering `retry.fallbackChains`, adding/removing external providers or authentication credentials.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Uniform Role Aliasing with `@smol`:** All subagents in `task.agentModelOverrides` map to the `@smol` alias instead of directly naming `google-antigravity/gemini-3.7-flash:high`. This ensures single-point configuration where tuning the light tier automatically updates all subagents. Governs R3, R5.
- KTD2. **Exhaustive Subagent Mapping:** Retain explicit entries for all seven bundled subagents (`task`, `designer`, `reviewer`, `security-reviewer`, `scout`, `librarian`, `sonic`) in `task.agentModelOverrides` to satisfy the exhaustiveness contract checked by `.ci/check-omp-agent-roster.sh`. Governs R5.
- KTD3. **Align Prose Documentation in AGENTS.md:** Update the model placement narrative in `AGENTS.md` to document that Claude Opus 5 is reserved for interactive session roles (`default`, `slow`, `plan`), and all subagents run on the light Gemini Flash tier. Governs R6.

### Assumptions

- The `omp` model catalog already authenticates `google-antigravity` via OAuth or env credentials.
- `google-antigravity/gemini-3.7-flash` reasoning levels admit `:high`.

---

## Implementation Units

### U1. Update modelRoles and task.agentModelOverrides in agents.yaml

- **Goal:** Remap `modelRoles.advisor` to `@smol`, and all `task.agentModelOverrides` (`designer`, `librarian`, `reviewer`, `scout`, `security-reviewer`, `sonic`, `task`) to `@smol`.
- **Files:** `.chezmoidata/agents.yaml`
- **Requirements:** R1, R2, R3, R4, R5
- **Approach:**
  1. In `agents.omp.settings.modelRoles`, set `advisor: "@smol"`.
  2. In `agents.omp.settings.task.agentModelOverrides`, set `designer: "@smol"`, `reviewer: "@smol"`, `security-reviewer: "@smol"`, and `task: "@smol"` (keeping `librarian`, `scout`, `sonic` at `@smol`).
- **Test Scenarios:**
  - Render `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` with chezmoi in scratch.
  - Parse rendered JSON and verify all 7 subagent overrides and `advisor` resolve to `@smol`.
- **Verification:** `chezmoi execute-template` in scratch with stub op.

### U2. Update model policy narrative in AGENTS.md

- **Goal:** Update `AGENTS.md` to reflect that Claude Opus 5 is reserved for user-interactive sessions (`default`, `slow`, `plan`), while all subagents and auxiliary roles run on the light Gemini Flash tier (`smol`).
- **Files:** `AGENTS.md`
- **Requirements:** R6
- **Approach:**
  1. Locate the model placement paragraph in `AGENTS.md`.
  2. Update the role descriptions for `default`, `slow`, `plan`, and subagents to match the updated configuration.
- **Test Scenarios:**
  - Verify prose accuracy against `.chezmoidata/agents.yaml`.
- **Verification:** Text inspection and `git diff --check`.

### U3. Run CI test suites for reconciliation and roster coverage

- **Goal:** Verify that catalog reachability, chain reachability, alias resolution, and agent roster checks pass.
- **Files:** None (verification only)
- **Requirements:** R7
- **Approach:**
  1. Run `.ci/test-omp-agent-reconcile.sh` with required fixtures.
  2. Run `.ci/check-omp-agent-roster.sh` with rendered settings script.
- **Test Scenarios:**
  - Reconciliation script succeeds with exit code 0.
  - Agent roster check confirms 7 bundled agents all mapped to declared keys.
- **Verification:** Both test scripts exit 0.

---

## Verification Contract

- **Automated Tests:**
  - `.ci/test-omp-agent-reconcile.sh`
  - `.ci/check-omp-agent-roster.sh <rendered-settings-script>`
- **Quality Gates:**
  - `git diff --check` passes with no whitespace or syntax issues.
  - Template rendering passes with no dangling aliases or unreachable chains.

---

## Definition of Done

- `.chezmoidata/agents.yaml` reflects `modelRoles.advisor: "@smol"` and all seven `task.agentModelOverrides` set to `@smol`.
- `AGENTS.md` accurately documents the model placement policy.
- `.ci/test-omp-agent-reconcile.sh` and `.ci/check-omp-agent-roster.sh` exit 0.
- No uncommitted or temporary files remain in the working tree.
