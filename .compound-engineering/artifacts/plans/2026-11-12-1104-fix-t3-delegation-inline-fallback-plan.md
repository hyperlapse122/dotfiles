---
title: T3 delegation before CE inline fallback - Plan
type: fix
date: 2026-11-12
topic: t3-delegation-inline-fallback
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# T3 delegation before CE inline fallback - Plan

## Goal Capsule

- **Objective:** When a CE skill in a T3 Code session calls for a subagent, the work shows up as a T3 child task the owner can track, not as inline work done because no native subagent tool was visible.
- **Means:** Reword the T3-only branch of the shared instruction template (KTD1, KTD2).
- **Product authority:** The settled decisions below and this Product Contract govern scope; `AGENTS.md` governs integration.
- **Execution profile:** One PR. LFG owns implementation, verification, review, and publication; merging stays with the owner.
- **Stop conditions:** A settled decision proves infeasible, or a required check is refused. Do not apply personal configuration.
- **Open blockers:** None.

---

## Product Contract

### Summary

Tell T3 sessions that the missing native subagent tool is intentional, that `delegate_task` is their subagent tool, and that they must load it before taking any CE fallback for missing subagents.

### Problem Frame

In T3 thread `12c327b9-bd7b-4068-b6de-962a2d0d9ffe` (Claude Opus 5.5 under T3 Code), `ce-simplify-code` told the model to dispatch reviewers. The model reasoned "Since I have no agent tool available, I'll do the review inline" and never loaded `delegate_task`. Four things combined:

1. T3 launches deny the native tool: Claude gets `--disallowedTools=Agent` and Codex disables `multi_agent` (`scripts/t3-instructions.py`).
2. `delegate_task` is a deferred MCP tool. It is absent from the visible tool list until the model loads it through tool discovery (ToolSearch in Claude Code).
3. The T3 branch says "Keep CE's existing retry, recovery, inline fallback, ..." but never says the native tool is missing on purpose, so CE's "no subagent tool, run inline" rule fires.
4. T3 Code's own system prompt (not repository-owned) says "Subagents: use your native tool when the child uses your provider ... (Claude `Agent` ...)". The T3 branch's sentence "Follow higher-priority host constraints" can be read as yielding to that guidance.

### Key Decisions

- **Keep the native tool denial and T3 routing.** Governs R1. (session-settled: user-approved — chosen over re-allowing native same-provider children to match T3 Code's own guidance: delegated work must stay manageable in T3, per R2 of the 2026-11-09 T3-managed CE delegation plan.)
- **Fix through wording only.** Governs R4. (session-settled: user-approved — chosen over setting `ENABLE_TOOL_SEARCH=false` or similar for T3 Claude launches so `delegate_task` is always loaded: avoids the per-session context cost of eagerly loading every MCP tool definition.)
- **Required content of the wording.** Governs R1–R3. (session-settled: user-approved — chosen over leaving the text unchanged and relying on the model: the observed failure shows the current text is not enough.)

### Requirements

- R1. The T3 branch states that the native subagent tool is intentionally unavailable in T3 sessions, and that wherever a CE rule depends on whether a subagent tool is available, `delegate_task` is that tool.
- R2. Before taking any CE fallback for missing subagents, a T3 session loads `delegate_task` and the related task tools through the host's tool-discovery primitive (such as ToolSearch) when they are deferred. It falls back inline only when `delegate_task` is still unavailable or the delegation fails. The rule does not authorize a delegated child to delegate further when its brief tells it to do the work itself; the existing rule that further delegation needs an assigned CE task that requires it still governs.
- R3. The T3 branch states that this routing overrides T3 Code's own guidance to use the native tool for same-provider children, while still honoring real higher-priority host constraints such as permission denials.
- R4. The wording is harness-neutral (it renders for Claude, Codex, and Pi). Launch options, tool exposure, the baseline instruction branch, and CE itself stay unchanged.
- R5. CE's own decisions to work inline stay intact: a lite review path, a Lightweight scan, or a skip condition does not acquire a child task because of this change.

### Acceptance Examples

- AE1. **Covers R1, R2.** A T3 Claude session runs a CE skill that says to dispatch reviewers. The session loads `delegate_task` through ToolSearch and dispatches the reviewers as T3 children instead of reviewing inline.
- AE2. **Covers R2.** `delegate_task` is loaded but the delegation fails. CE's existing recovery or inline fallback decides what happens next, with no new failure policy.
- AE3. **Covers R5.** `ce-code-review` selects its lite path for a small test-only diff. The review still runs inline, because CE chose inline for reasons unrelated to tool availability.

### Scope Boundaries

The change owns the T3 branch wording and its mirror in `docs/agent-routing.md`. It does not change launch arguments, environment, tool deferral, the baseline branch, CE plugin files, or T3 Code. It does not force CE to delegate work its skill would perform inline. A prompt addition is guidance, not tool-level enforcement.

### Sources / Research

- Thread `12c327b9-bd7b-4068-b6de-962a2d0d9ffe`, activity items 72–73: the inline decision and its stated reason.
- `home/h82/agents/instructions/instructions.md.tmpl:1-36`: the `.t3` branch, sections `# T3 delegation` and `# T3 CE model selection`.
- `scripts/t3-instructions.py:14-20`: `NATIVE_CONTROLS` denies Claude `Agent` and disables Codex `multi_agent*`.
- `docs/agent-routing.md:7-17`: verbatim mirror of the T3 delegation section; `AGENTS.md` requires keeping it aligned.
- `.compound-engineering/artifacts/plans/2026-11-09-0127-fix-t3-managed-ce-delegation-plan.md`: origin of the current T3 delegation wording and its "does not force CE to delegate" boundary.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Put the new rule in the existing `# T3 delegation` section rather than a new section. Narrow the sentence "Follow higher-priority host constraints." so it names real host constraints (such as permission denials) and states that T3 Code's guidance to use a native subagent tool for same-provider children does not apply, because these sessions disable that tool. Implements R3.
- KTD2. Extend the paragraph that begins "Keep CE's existing retry, recovery, inline fallback" with the R1 and R2 rule: the native tool is intentionally unavailable, `delegate_task` counts as the subagent tool for CE's availability checks, and a deferred `delegate_task` must be loaded through tool discovery before any fallback for missing subagents. Tie the rule to the existing sentence "Authorize further delegation only when its assigned CE task requires it." so a leaf child told to do the work itself stays inline. Name ToolSearch only as an example, so Codex and Pi wording stays valid. Implements R1, R2, R4, R5.
- KTD3. Add no new repository check. The existing checks already prove delivery: `agent-instructions` proves the baseline renders without the T3 branch and the T3 render carries `T3 delegation`, and `t3code-launch.py` (in `t3code-traits`) proves the Claude and Pi additions carry the section and that Codex receives `developer_instructions`. Codex parity with the new wording rests on the shared render. A substring check for the new sentence would pass a negated sentence (see the substring-sentence learning) and cannot prove model compliance, which is the actual failure. Implements R4.

### Directional wording

This sketch shows intent, not final text; the implementer edits for flow and runs `ce-noslop` on it.

> Follow higher-priority host constraints, such as permission denials. T3 Code's own guidance to use a native subagent tool for same-provider children does not apply here: these sessions disable that tool on purpose, so this routing wins.
>
> The native subagent tool is intentionally unavailable in T3 sessions. Wherever a CE rule depends on whether a subagent tool is available, `delegate_task` is that tool. When it is deferred, load it and the related task tools through the host's tool discovery (such as ToolSearch) before concluding that no subagent is available. Take CE's inline fallback only when `delegate_task` is still unavailable or the delegation fails. A child whose brief says to do the work itself still does it itself.

### Assumptions

- Changing only the `.t3` branch leaves the baseline receipts in `tests/agent-instructions.py` unchanged, because those receipts hash the baseline render. If the check reports a receipt mismatch, update the hashes as `AGENTS.md` requires.
- No test compares `docs/agent-routing.md` with the template; alignment is a manual mirror.
- `tests/t3code-launch.py` asserts `'writing' not in addition.lower()`. The new wording must not contain that substring (for example "rewriting" or "overwriting").

## Implementation Units

### U1. Reword the T3 delegation section and mirror it

- **Goal:** Deliver R1–R5 through the existing T3-only addition.
- **Requirements:** R1–R5; KTD1, KTD2, KTD3.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `docs/agent-routing.md`; `tests/agent-instructions.py` only if receipts change.
- **Approach:** Edit the `.t3` branch per KTD1 and KTD2 and leave `# T3 CE model selection` and the baseline branch untouched. Copy the resulting `# T3 delegation` body verbatim into `docs/agent-routing.md` under `## T3 delegation`. Keep the template's Go `text/template` syntax unchanged and add no template actions.
- **Test scenarios:** The rendered T3 addition carries the new rule once and keeps `# T3 delegation` and `# T3 CE model selection`; the baseline renders for every harness exclude it; the Claude and Pi additions carry it, and Codex receives `developer_instructions` from the same render. Covered by the existing `agent-instructions` and `t3code-traits` checks; Codex wording parity rests on the shared render and the manual render diff.
- **Verification:** `nix build --no-link .#checks.x86_64-linux.agent-instructions` and `.#checks.x86_64-linux.t3code-traits`; render the `.t3` branch with `packages/text-template` and diff the section against `docs/agent-routing.md`.

## Verification Contract

- `nix build --no-link .#checks.x86_64-linux.agent-instructions`
- `nix build --no-link .#checks.x86_64-linux.t3code-traits`
- `nix fmt -- --ci`, `git diff --check`, and `markdownlint-cli2` on changed Markdown.
- `nix flake check` on the local builder when time allows; otherwise record it as deferred to CI.
- The PR carries the `full-ci` label, and readiness needs a green run on the head commit with `host-checks`, `vm-checks`, `build`, and `build-darwin`.
- Model compliance (AE1) is not provable by repository checks; the PR states that a later T3 session is the evidence.

## Definition of Done

The T3 branch and `docs/agent-routing.md` carry the same R1–R3 wording, the listed checks pass or are recorded as deferred with their cause, no baseline text or launch option changed, and the change is published in one open PR with CI decided.
