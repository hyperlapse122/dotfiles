---
title: OMP Luna Light-Role Policy - Plan
type: chore
date: 2026-07-31
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# OMP Luna Light-Role Policy - Plan

## Goal Capsule

- **Objective:** Replace the live OMP policy placements of `openai-codex/gpt-5.4-mini` with `openai-codex/gpt-5.6-luna` while preserving useful fallback recovery.
- **Authority:** The user request defines the model change. `.agents/skills/sync-omp-models/SKILL.md` defines policy legality and verification. Repository instructions define chezmoi isolation and delivery.
- **Execution profile:** One bounded policy update plus its machine-checked rationale companion.
- **Stop conditions:** Stop if Luna is absent from the live OMP catalog, loses the light-role capability fit, or the rendered policy violates fallback anchors.
- **Tail ownership:** LFG owns review, commit, pull request, CI, and merge after implementation returns.

## Product Contract

### Summary

Move the OMP light-role policy from GPT Mini to GPT Luna. Keep the policy auditable, available on this host, and recoverable across providers.

### Problem Frame

The current policy still names `gpt-5.4-mini` as the `smol` primary and as the OpenAI hop in the `bulk` fallback chain. The requested Luna replacement is a cross-family policy decision, not an automatic version float. A literal replacement would also duplicate Luna inside the `smol` and `commit` recovery paths because those chains already contain Luna.

### Requirements

- R1. `agents.omp.settings.modelRoles.smol` uses `openai-codex/gpt-5.6-luna` instead of `openai-codex/gpt-5.4-mini`.
- R2. `agents.omp.settings.retry.fallbackChains.bulk` uses Luna instead of Mini for its OpenAI light-tier anchor.
- R3. The resolved `smol` and `commit` fallback paths do not retry their Luna primary as a chain hop.
- R4. The model-policy comments and role-to-family documentation describe Luna as the selected light family.
- R5. Every declared selector remains available, and every fallback path retains Anthropic and OpenAI anchors without escalating a light role to a deliberation tier.
- R6. The change does not alter unrelated model providers, roles, overrides, credentials, themes, or non-OMP Mini references.

### Scope Boundaries

- Update `.chezmoidata/agents.yaml` and the machine-checked role mapping in `.agents/skills/sync-omp-models/model-notes.md`.
- Keep the general GPT Mini family note because it remains valid reference material even when no role selects that family.
- Do not edit historical plans or `dot_config/cli-proxy-api/readonly_config.yaml`.
- Do not run a live `chezmoi apply`; deployment remains a separate user action.

## Planning Contract

### Key Technical Decisions

- KTD1. **Treat Mini to Luna as a deliberate family change.** The live OMP 17.2.1 catalog exposes both selectors with tool-capable reasoning. The GPT Mini family note identifies subagents as its exact target, while the GPT Luna family note describes bounded high-volume tool loops with stronger reasoning. The user chose Luna over Mini, so this policy accepts the utility-agent alignment tradeoff instead of presenting the change as an automatic version float.
- KTD2. **Keep role-based propagation.** Change `smol` once so bundled consumers that resolve through `@smol` receive Luna without duplicate agent overrides.

### Assumptions

- Remove Luna from the `smol` and `commit` fallback chains after Luna becomes their resolved primary. Do not add a replacement hop because the remaining chains preserve cross-provider recovery and both anchor providers.
- Refresh the nearby bundled-agent version comment to the observed OMP 17.2.1 defaults if the existing version text is stale. This is comment accuracy, not a new override.
- Preserve fallback order outside the redundant Luna removals and the requested `bulk` substitution.

### Sources and Research

- `.agents/skills/sync-omp-models/SKILL.md` defines the cross-family decision rule, role aliases, anchor providers, required inputs, and isolated verification.
- `.agents/skills/sync-omp-models/model-notes.md` records the strongest evidence on both sides: GPT Mini targets subagents and precise high-volume chores, while GPT Luna targets bounded high-volume tool loops that need real reasoning. The requested policy favors Luna's reasoning profile over Mini's closer utility-agent match.
- The installed OMP 17.2.1 taxonomy contains the configured built-in roles. Its live catalog contains both requested selectors and all configured providers.
- The current oh-my-openagent matching guide still prefers GPT Mini for utility agents but uses GPT Luna for bounded low-effort work. This policy intentionally follows the user's Luna choice while retaining the local light-tier constraints.
- No `docs/solutions/` or `CONCEPTS.md` corpus exists in this repository.

## Implementation Units

### U1. Retune the OMP light policy

- **Goal:** Apply the Luna family decision and keep each affected recovery path useful.
- **Requirements:** R1, R2, R3, R4, R5, R6; KTD1, KTD2.
- **Dependencies:** None.
- **Files:**
  - `.chezmoidata/agents.yaml`
  - `.agents/skills/sync-omp-models/model-notes.md`
  - Existing verification: `.ci/test-omp-agent-reconcile.sh`
- **Approach:**
  1. Change the `smol` primary and the `bulk` OpenAI fallback from Mini to Luna.
  2. Remove the now-redundant Luna hop from the `smol` and `commit` chains while preserving their remaining order.
  3. Update the model-policy comments, current bundled-agent binding note, role-to-family rows, OMO (oh-my-openagent) comparison, and substitution guidance that would otherwise describe Mini as the selected family.
  4. Leave overrides and unrelated settings byte-identical.
- **Patterns to follow:** Use role aliases for propagation, keep fallback-chain keys role-scoped, and preserve the anchor-provider rule from `.agents/skills/sync-omp-models/SKILL.md`.
- **Test scenarios:**
  - Render the policy with a scratch `HOME` and stubbed `op`; all five required artifacts render without a validation error or secret access.
  - Compare declared selectors to `omp models --json`; the used-selector difference is empty and Luna is available.
  - Resolve every role path; each declared fallback chain reaches Anthropic and OpenAI, every affected selector stays on a light tier, and `smol` and `commit` do not repeat their resolved primary.
  - Run the existing OMP reconcile integration; shell and PowerShell settings assertions match and the test reports success.
  - Run the model-notes check; family coverage, role mappings, and spec-leak checks report zero problems.
  - Inspect the final data; `.chezmoidata/agents.yaml` contains no `gpt-5.4-mini`, while unrelated repository references remain untouched.
- **Verification:** The exact isolated Verify recipe in `.agents/skills/sync-omp-models/SKILL.md` passes. Direct inspection confirms that the `smol` and `commit` chain blocks do not contain their Luna primary and that the rendered policy selects Luna at the intended sites.

## Verification Contract

| Gate | Applies to | Done signal |
|---|---|---|
| Scratch chezmoi renders | U1 | All five required artifacts render under a stubbed secret path with no validator failure. |
| Live selector availability | U1 | The declared-selector set is a subset of the live OMP catalog. |
| Fallback integrity | U1 | Anchor checks are silent; direct inspection confirms the `smol` and `commit` chain blocks do not contain their Luna primary and every affected selector stays on a light tier. |
| OMP reconcile integration | U1 | `.ci/test-omp-agent-reconcile.sh` reports that auth, plugin, and settings reconciliation passed. |
| Model-family documentation | U1 | The model-notes validator reports `problems=0`. |
| Repository checks | U1 | `.chezmoidata/agents.yaml` contains no `gpt-5.4-mini`; repository `CLAUDE.md` mirrors remain exact; `git diff --check` and the scope-limited diff pass. |

## Definition of Done

- R1-R6 are satisfied in the rendered source state.
- U1 completes every test scenario and Verification Contract gate.
- Model-role comments and `model-notes.md` agree with the selected Luna family and current bundled bindings.
- No credentials, live deployed files, or unrelated model policy are changed.
- No abandoned or experimental changes remain in the diff.
- The branch is committed, pushed, reviewed, and merged through the repository's required CI workflow.
