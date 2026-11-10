---
title: T3 CE model ladder - Plan
type: feat
date: 2026-11-10
topic: t3-ce-model-ladder
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# T3 CE model ladder - Plan

## Goal Capsule

- **Objective:** CE work delegated inside T3 Code runs each child on a model sized to its role, so the owner stops paying orchestrator-model time and cost for scouts, workers, and routine reviewers.
- **Means:** Extend the existing T3-only instruction addition with per-provider model ladders and role placement rules.
- **Product authority:** The confirmed brainstorm dialogue and this Product Contract govern scope; repository instructions govern integration.
- **Execution profile:** One PR. LFG owns implementation, verification, review, and publication; merging remains with the owner.
- **Stop conditions:** A settled decision proves infeasible, or a required check is refused. Do not apply personal configuration.
- **Open blockers:** None.

---

## Product Contract

### Summary

Add per-provider model ladders to the T3-only instructions.
When a CE skill delegates a child, the orchestrator picks the ladder rung for the child's role on its own provider and leaves effort at T3's default for that model.
A child never runs above the orchestrator's own rung.

### Problem Frame

CE skills assign children to tiers by task shape: the cheapest capable model for extraction, a mid-tier model for mechanical verification, the session model for the highest-stakes reviewers and for implementation workers.
The skills name no models. When the host exposes no known override, they inherit the orchestrator's model.

The T3 addition tells agents to preserve CE's model selection and to resolve it through T3 capability discovery, but it carries no table that turns a CE tier into a model.
In practice every child inherits. The owner observed scouts and workers running on Claude Fable 5.2 at medium effort, the same as the orchestrator.

### Key Decisions

- **Stay inside the orchestrator's provider.** Governs R1, R2. (session-settled: user-directed — chosen over one provider-agnostic table: the same account and model behavior keep results predictable.)
- **Core reviewers take the top child rung; implementation takes the middle rung.** Governs R3, R4. (session-settled: user-directed — chosen over placing implementation workers on the top child rung with the core reviewers: the owner accepts more review-and-fix rounds for lower cost.)
- **Effort follows T3's per-model default.** Governs R6. (session-settled: user-directed — chosen over a fixed effort per rung, low effort everywhere, and inheriting the orchestrator's effort: the rule stays simplest. Known consequence: Codex `gpt-6.1-sol` and `gpt-6.1-terra` children run at low effort while Claude Sonnet children run at high.)
- **The orchestrator's model caps its children.** Governs R7. (session-settled: user-approved — chosen over applying the ladder regardless of the session model, and over applying it only in top-model sessions: a session opened on a cheaper model keeps that intent.)
- **Antigravity keeps Argon for core reviewers only.** Governs R2, R3. (session-settled: user-approved — chosen over sending only scouts to Flash, and over reserving Argon for the orchestrator: it matches the decision to move implementation down a rung.)
- **An explicitly named model wins over the ladder.** Governs R8. The user confirmed this in the scope synthesis; CE's own tier rules already give named models precedence.

### Requirements

**Ladders**

- R1. In a T3-launched session, a CE-delegated child runs on the orchestrator's provider at the rung R3–R5 assign to its role, unless CE selects a different provider for that child.
- R2. The ladders are:

  | Provider | Orchestrator | Top child rung | Middle rung | Bottom rung |
  |---|---|---|---|---|
  | Claude | Fable | Opus | Sonnet | Haiku |
  | Codex | `gpt-6-astra` | `gpt-6.1-sol` | `gpt-6.1-terra` | `gpt-6-luna` |
  | Synthetic through pi | latest Kimi | latest GLM | latest GLM Flash | latest DeepSeek Flash |
  | Antigravity | Gemini 4 Argon | Gemini 4 Argon | Gemini 3.8 Flash | Gemini 3.8 Flash |

**Role placement**

- R3. The top child rung runs the reviewers CE assigns to the session model: `correctness-reviewer`, `security-reviewer`, `adversarial-reviewer`, and the document reviewers CE tells to inherit the parent model.
- R4. The middle rung runs implementation workers, CE's mid-tier and generation-tier children, and any CE child whose skill names no tier.
- R5. The bottom rung runs CE's extraction-tier and cheapest-capable children, such as grounding scouts.

**Effort, cap, and precedence**

- R6. When no effort is named for a child, the orchestrator sets none and T3's default for the chosen model applies.
- R7. A child never runs on a rung above the orchestrator's own. A role placed higher runs on the orchestrator's model, or under R9 on the other provider's model in the orchestrator's column of R2.
- R8. A model or effort named for a child by the user's prompt or by CE configuration overrides R1–R7 for that child. This includes `cross_model_model`, `cross_model_effort`, `work_engine_preferences`, `work_engine_effort`, `plan_model`, and `brainstorm_model`.
- R9. When CE selects another provider for a child, such as a cross-model review peer, the child runs on that provider's ladder at the rung R3–R5 assign to its role.
- R10. Each "latest" entry in R2 resolves at delegation time to the newest model of that family in T3's catalog, not to a pinned model ID.

**Integration and evidence**

- R11. The rules reach supported harnesses through the existing shared T3-only addition. Direct CLI sessions, shared homes, credentials, and the repository-owned CE installation stay as they are.
- R12. Verification reports which model observed child tasks ran on, separately from proof that the instruction text was delivered.

### Acceptance Examples

- AE1. **Covers R1, R2, R5, R6.** Given a Claude Fable orchestrator running a Standard CE brainstorm, the grounding scout appears as a T3 child on Claude Haiku with no effort option set.
- AE2. **Covers R3, R4.** Given a Claude Fable orchestrator running a CE code review, `correctness-reviewer` runs on Opus and a mid-tier persona runs on Sonnet. A CE implementation worker in the same session runs on Sonnet.
- AE3. **Covers R7.** Given a Claude Sonnet orchestrator, `security-reviewer` runs on Sonnet and a scout runs on Haiku.
- AE4. **Covers R6, R8.** Given `cross_model_model` set to a specific model, the cross-model peer runs on that model even when the ladder would pick another. Given `cross_model_effort: xhigh`, the peer receives that effort.
- AE5. **Covers R7, R9.** Given a Claude Fable orchestrator whose CE review selects Codex as the adversarial peer with no model configured, the peer runs on `gpt-6.1-sol`. Given a Claude Sonnet orchestrator, the same peer runs on `gpt-6.1-terra`.
- AE6. **Covers R2, R3, R4, R9.** Given a Claude, Codex, or pi orchestrator whose CE skill selects Antigravity for a child, a core reviewer runs on Gemini 4 Argon, and an implementation worker or scout runs on Gemini 3.8 Flash.
- AE7. **Covers R10.** Given a newer GLM Flash model added to T3's catalog, the next Synthetic middle-rung child uses it with no change to the instructions.
- AE8. **Covers R11.** Given a Grok orchestrator, or a delegation no CE skill dispatched, model selection behaves as it does today.

### Scope Boundaries

- Providers without a ladder in R2, including Grok, keep current behavior.
- Delegations outside CE skills keep current behavior.
- An Antigravity-hosted orchestrator keeps current behavior, because T3 delivers no T3-only addition to that provider. The Antigravity ladder applies only through R9.
- The change adds no native enforcement. A prompt addition cannot guarantee that a model follows it, and higher-priority host instructions remain binding.
- The change does not fork CE, edit cached plugin files, or alter which children CE dispatches, their briefs, or their output contracts.
- Fixed effort per rung is deferred; revisit it if the low-effort Codex defaults or the high-effort Sonnet default cause problems.

### Dependencies / Assumptions

- T3's `delegate_task` accepts a per-child model, and `orchestrator_capabilities` lists each provider's models and default options. Both were observed in this session.
- The pi provider's T3 catalog currently lists Kimi K3.1 Pro, GLM 5.3, GLM 5.3 Flash, and DeepSeek V4.1 Flash. R10 assumes an agent can tell which listed model is newest in a family from its name.
- The T3 Code 0.1.7 Grok driver cannot receive a T3-only prompt addition, per `docs/guides/t3-code.md`. Grok has no ladder, so this does not narrow R11.
- T3-only additions render for Claude, Codex, and pi only (`T3_ADAPTERS` in `tests/test_agent_instructions.py`). The Antigravity decision was settled on the assumption that an Antigravity orchestrator would follow its ladder; that case cannot be delivered through R11's mechanism, so AE6 covers the CE-selected Antigravity child instead.

### Sources / Research

- `home/.chezmoitemplates/agent-instructions:1-13`: the current T3-only delegation addition, including "do not silently inherit a different model or effort".
- `docs/guides/t3-code.md`, "Instructions shared with the terminal": delivery mechanism, CLI isolation, and the delivery-versus-compliance evidence boundary.
- `.compound-engineering/artifacts/plans/2026-11-09-0127-fix-t3-managed-ce-delegation-plan.md`: the plan that routed CE delegation through T3 and kept CE's model selection.
- Installed Compound Engineering, `skills/ce-brainstorm/references/model-tiers.md`: extraction, generation, and ceiling tiers, the inherit-when-unknown rule, and precedence for a named model.
- Installed Compound Engineering, `skills/ce-code-review/references/dispatch-reviewers.md`, "Model tiering": three reviewers inherit the session model; every other persona uses the mid-tier model.
- Installed Compound Engineering, `skills/ce-doc-review/references/dispatch.md`: per-reviewer tiers for document review.
- [Anthropic, multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system): an Opus lead with Sonnet subagents outperformed a single Opus agent on Anthropic's internal research evaluation.
- Community write-ups on Claude Code subagent routing and Aider's architect/editor split place workers one rung below the planner and warn against running every agent on either the top or the bottom model. No benchmark for reviewer tiering was found.

---

## Planning Contract

Product Contract preservation: changed: AE6 and one Scope Boundaries bullet — an Antigravity orchestrator receives no T3-only addition, so its ladder is reachable only through R9. Clarified after document review: R7 and AE5 say how the cap applies across providers, and R6, R8, and AE4 pass a named effort through. Neither clarification alters a settled decision.

### Key Technical Decisions

- KTD1. **Add one new section to the T3 branch of the shared template, after `## T3 delegation`.** The section holds the ladder table and the placement, effort, cap, and precedence rules. The existing delegation section keeps its text except for the sentence KTD2 changes. One section renders once in each Claude, Codex, and pi addition and nowhere in the baseline.
- KTD2. **Reword "do not silently inherit a different model or effort" so it defers to the new section.** CE's tier rules say to inherit when model names are unknown. The new section supplies the names, so the delegation section must say that a CE tier or a CE "inherit" resolves through the ladder, and that only R8's named models pass through unchanged.
- KTD3. **Name model families, not model IDs.** The instruction names each rung by family (`Opus`, `sol`, `GLM Flash`) and tells the agent to pick the newest listed model of that family from `orchestrator_capabilities`. This satisfies R10 for Synthetic and keeps the Claude and Codex rows from going stale at the next model release. Today the families resolve to the IDs in R2.
- KTD4. **A child that delegates further applies the same rules with its own model as the cap.** R7 already caps children at the orchestrator's rung, and a delegating child is the orchestrator of its own children. The existing rule that each brief carries the routing policy delivers the ladder to children that receive no addition of their own.
- KTD5. **When the catalog lacks a rung's family, use the next lower listed rung of the same provider, then the next higher rung within R7's cap, then the delegating model.** Stepping down keeps the cost intent of R1, staying on the provider keeps CE's provider choice, and the delegating model is the last resort that keeps the work running. The agent states the substitution in its report, consistent with the existing rule against treating task completion as proof of serving-model identity.
- KTD6. **Leave effort unset by omitting the effort option from `target.options`, and pass a named effort through it.** R6 needs no mapping table, and T3 applies the model's default when the option is absent. CE's own editorial effort defaults for peers are not a named effort; only R8's sources are.
- KTD7. **Prove routing with a bounded live probe from this T3 session, not a new test harness.** Rendering tests and the native request-capture smoke prove delivery. Observed child models from real `delegate_task` calls supply R12's separate evidence. The probe applies no personal configuration: it passes the rendered section in the child brief.

### Assumptions and Limits

- The addition is a prompt. It cannot override higher-priority host instructions, and no application-code enforcement is proposed.
- `delegate_task` reports the model each child was started with. The probe records that requested model and does not claim it as verified serving identity.
- The smoke's fixture transport rejects real completions, so it shows the section reaches the native request and nothing about model compliance.

---

## Implementation Units

### U1. Add the model ladder section and rendering coverage

- **Goal:** Deliver the ladder and its rules through every existing T3-only addition.
- **Requirements:** R1–R11; the Product Contract Key Decisions governing R1–R4, R6, R7, and R8; KTD1–KTD6.
- **Dependencies:** None.
- **Files:** `home/.chezmoitemplates/agent-instructions`, `tests/test_agent_instructions.py`, `tests/smoke_t3_instructions.py`.
- **Approach:**
  1. Add the section per KTD1, with the R2 ladder as a table of families per KTD3.
  2. State R3–R5 placement by CE's own tier words: session-model reviewers, mid-tier and generation-tier, extraction-tier and cheapest-capable, and unnamed-tier children.
  3. State R6–R9 and KTD4–KTD6 in one short rule each, including the cross-provider cap in R7.
  4. Apply KTD2's rewording in the delegation section.
  5. Extend the existing T3-only assertions and the smoke's `check_context` markers to cover the new section.
- **Patterns to follow:** `test_delegation_policy_is_only_in_t3_additions` in `tests/test_agent_instructions.py`; `check_context` in `tests/smoke_t3_instructions.py`.
- **Test scenarios:**
  - Each Claude, Codex, and pi T3 addition, on every rendered operating system, contains the new section heading exactly once.
  - Each addition names every family in R2 and the words that carry R6, R7, and R8.
  - Each addition no longer contains the former "do not silently inherit a different model or effort" sentence.
  - Every baseline adapter, on every rendered operating system, contains neither the section heading nor a ladder family row.
  - The smoke's native request capture for a T3 launch contains the section heading and a ladder marker, and a direct CLI launch contains neither.
- **Verification:** The focused instruction tests pass, and the native instruction smoke passes in a disposable home on the local platform.

### U2. Document the ladder and record observed routing

- **Goal:** Describe the ladder in the T3 guide and report which models real children ran on.
- **Requirements:** R11, R12; KTD7. Covers AE1–AE3 by observation where the session can reach them.
- **Dependencies:** U1.
- **Files:** `docs/guides/t3-code.md`.
- **Approach:**
  1. In "Instructions shared with the terminal", replace the sentence that says CE selects model and effort without inheritance with a description of the ladder, the cap, effort defaults, named-model precedence, and the Antigravity and Grok limits.
  2. Run the probe in KTD7: from this session, delegate one extraction-shaped child and one mid-tier child by the rendered rules, and delegate one child on a lower rung that is told to dispatch an extraction child, to exercise the cap.
  3. Record requested provider, model, and effort for each probe child in the PR description, and label anything not exercised as unobserved.
- **Test scenarios:** Test expectation: none -- documentation and a manual probe; U1 carries the automated coverage.
- **Verification:** The guide matches the rendered section, and the PR description lists the probe children with their models or names the probes that could not run and why.

---

## Verification Contract

| Check | Command | Applies to |
|---|---|---|
| Instruction rendering | `python3 -B -m unittest discover -s tests -p test_agent_instructions.py` | U1 |
| Composer and settings regressions | `python3 -B -m unittest discover -s tests -p test_t3_instructions.py` and the same for `test_t3_code_settings.py` | U1 |
| Native request capture | `mise exec chezmoi python -- python tests/smoke_t3_instructions.py` in a disposable home | U1 |
| Whitespace | `git diff --check` | U1, U2 |
| Observed routing | T3 child task records from the KTD7 probe | U2 |

Record any check the local platform or runtime cannot run, with its cause.

---

## Definition of Done

- U1's section and tests agree, and every automated check above passes or is named as unavailable with its cause.
- U2's guide text matches the rendered section, and the PR description reports observed child models separately from delivery proof.
- No personal configuration was applied, and no probe children or abandoned experiments remain.
- The reviewed change is committed and published in one open PR.
