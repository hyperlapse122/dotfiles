---
title: Resolve Planning Open Questions - Plan
type: feat
date: 2026-09-18
product_contract_source: ce-plan-bootstrap
execution: code
artifact_contract: ce-unified-plan/v1
---

# Resolve Planning Open Questions - Plan

## Goal Capsule

- **Objective:** A `ce-brainstorm`, `ce-plan`, or `ce-doc-review` run resolves an in-scope open question, gap, or fork it can settle, instead of leaving it in a deferred bucket for a later stage to pick up.
- **Means:** Add one dedicated paragraph to the shared instruction core (`home/.chezmoitemplates/agents-instructions.tmpl`) that names the three skills and overrides their own deferral-bucket instructions, by the file's existing precedence rule (KTD1).
- **Authority hierarchy:** Repository `AGENTS.md` > this plan > the upstream Compound Engineering skill reference files the new paragraph overrides.
- **Stop conditions:** the rendered instruction differs across the three harness targets outside the sanctioned per-harness paragraphs; the new text lands between the two fixture-locked autonomy paragraphs or otherwise breaks `.ci/test-agent-instructions.sh`.
- **Execution profile:** single-file doctrine edit, small blast radius, verified by a local scratch chezmoi render plus the repo's existing CI gate.
- **Who finishes and ships:** the implementing agent, through `ce-work`, `ce-commit-push-pr`, and CI-watch to a merged PR.

## Product Contract

### Summary

Issue #562 reports that `ce-brainstorm` and `ce-plan` habitually defer in-scope open questions — Outstanding Questions, Open Questions, `Resolve Before Planning`, `Deferred to Planning`, `Deferred to Implementation` — instead of resolving them during planning. The instruction core already states a related rule, but it sits inside an unrelated review-and-blocker paragraph, far from the planning workflow, so the upstream skills' own section contracts win in practice. Add a paragraph in the shared instruction core, beside the other `ce-plan`/`ce-brainstorm`-specific overrides already in the "Routing and mirrors" section, that makes the three planning/review skills resolve what they can and reserves deferral for genuine execution-time unknowns and out-of-scope work.

### Problem Frame

`ce-plan` and `ce-brainstorm`'s own reference files instruct deferral for outstanding questions and forks (`ce-brainstorm/references/brainstorm-sections.md:156-157`, `ce-plan/references/plan-sections.md:331`, `ce-plan/references/structure.md:125-129`). The instruction core's closest existing rule (`agents-instructions.tmpl:128`, inside "Branches, commits, issues, blockers") is about review findings and end-of-run blockers, not about the planning skills by name, so it does not reliably override those skills' own deferral instructions in practice.

### Requirements

- R1. `ce-brainstorm`, `ce-plan`, and `ce-doc-review` MUST resolve an in-scope open question, gap, or fork from repository evidence, research, or a stated assumption during their own run, instead of writing it into an Outstanding-Questions/Open-Questions/deferred bucket the run could settle now.
- R2. When resolving a question needs implementation work, the run MUST record that work as an Implementation Unit or a requirement, not as a `Deferred to Follow-Up Work` or `Deferred to Implementation` entry.
- R3. Only a product, design, or requirements choice the run cannot derive stays open: the run asks it when a human is present, and records a default as an explicit assumption in an unattended run.
- R4. A genuinely execution-time unknown — an answer that needs code changes, runtime behavior, or execution-time discovery — still uses `Deferred to Implementation`; that use of the bucket is unchanged.
- R5. `Outside this product's identity`, a true non-goal, and tangential work outside the confirmed scope still render under their existing scope-exclusion sections; the new rule does not fold these into "resolve now."
- R6. The new paragraph renders identically into all three harness-native instruction files (verified via the sanctioned scratch render, never live `$HOME`), and `.ci/test-agent-instructions.sh` continues to pass.

### Scope Boundaries

- **In scope:** one new paragraph in `home/.chezmoitemplates/agents-instructions.tmpl`.
- **Not building:** a Compound Engineering overlay patching `ce-brainstorm`/`ce-plan`/`ce-doc-review`'s own upstream reference files directly — the issue's candidate mechanism 2, rejected as a costlier alternative for the same requirement in KTD1, not excluded as outside this change's identity.
- **Deferred to Follow-Up Work:** none identified; the change is self-contained to the one paragraph.

### Sources

- Issue: https://github.com/hyperlapse122/dotfiles/issues/562
- `home/.chezmoitemplates/agents-instructions.tmpl:9` (precedence/composition rule the new paragraph invokes)
- `home/.chezmoitemplates/agents-instructions.tmpl:33-35` (existing `ce-plan`/`ce-brainstorm`-specific override paragraphs in the same section — the placement precedent)
- `home/.chezmoitemplates/agents-instructions.tmpl:128` (the existing, buried "resolve, don't defer" sentence the issue cites)
- `AGENTS.md:84` (fixture-lock contract for the `lfg` autopilot and workflow-required-step paragraphs — establishes that the new paragraph must not sit between them, and is itself not fixture-bound)
- `.ci/test-agent-instructions.sh:19-32,762-827` (the anchor check and the BANNED-phrase/needle gates the new text must not collide with)
- Compound Engineering 3.26.3 `ce-brainstorm/references/brainstorm-sections.md:156-157`, `ce-brainstorm/references/handoff.md:54-58` (`Resolve Before Planning` / `Deferred to Planning`)
- Compound Engineering 3.26.3 `ce-plan/references/structure.md:12-14,125-129` ("Resolved during planning" vs. "Deferred to implementation"; 3.7 Anti-Expansion)
- Compound Engineering 3.26.3 `ce-plan/references/plan-sections.md:331` ("defer forks to Open Questions rather than specifying both arms")

## Planning Contract

### Key Technical Decisions

- KTD1. **Add a dedicated paragraph to the shared instruction core; do not patch the upstream Compound Engineering skill files.** The file's own precedence rule ("A skill's own instructions... yield to this file", `agents-instructions.tmpl:9`) already gives a named paragraph override authority over `ce-brainstorm`/`ce-plan`/`ce-doc-review`'s own deferral-bucket prose — the same mechanism the file already uses for the learnings-researcher and model-elevation overrides immediately above the insertion point. The issue's alternative (a Compound Engineering overlay patching `brainstorm-sections.md`/`structure.md` directly) is explicitly costlier per the issue's own text ("stronger but must be refreshed on every plugin bump"), and this repo already reserves the overlay mechanism for patching an executable script an instruction can't redirect (the `elevation-dispatch.sh` overlay, per `AGENTS.md`'s "Agent surfaces and ownership" section) — not prose a model reads and follows. Rejected: the overlay mechanism — same outcome, higher maintenance cost, no plugin-bump-proof benefit for prose the precedence rule already overrides.
  - *Why a new paragraph succeeds where the existing line-128 sentence does not:* the issue's own diagnosis is that the existing sentence is generic (it never names `ce-brainstorm`, `ce-plan`, or `ce-doc-review`) and sits inside an unrelated review-and-blocker paragraph, so an upstream skill's own, specific deferral-bucket instructions win by specificity even though the general precedence rule technically covers them. The learnings-researcher and model-elevation paragraphs immediately above the insertion point follow the opposite pattern — name the CE skill, state the override plainly, cite no ambiguity — and are demonstrated working overrides: this very planning run followed the learnings-researcher paragraph's inline-search instruction rather than dispatching a subagent, in this same session. The new paragraph copies that skill-naming, unambiguous pattern rather than relying on a generic sentence to be read as skill-specific.
- KTD2. **Preserve `Deferred to Implementation` for genuine execution-time unknowns, and `Deferred to Follow-Up Work`/`Outside this product's identity` for out-of-scope work; target only in-scope, plan-time-answerable deferral.** `ce-plan`'s own Phase 2 already distinguishes "Resolved during planning" (knowable from repo context, docs, or user choice) from "Deferred to implementation" (depends on code changes, runtime behavior, or execution-time discovery) — that split is correct, and Core Principle 5 ("separate planning from execution discovery") depends on it. Issue #562's own acceptance criteria keep non-goals and `Outside this product's identity` rendering, and `structure.md:125-129`'s Anti-Expansion bucket is a legitimate scope-boundary tool, not the habit the issue reports. Rejected: a blanket "never defer" instruction — it would contradict `ce-plan`'s own execution/planning boundary and the issue's own acceptance criteria.
- KTD3. **Placement: insert the new paragraph in "## Routing and mirrors," directly after the existing learnings-researcher override paragraph and before the OS-conditional Orca-executable block; never between the two fixture-locked autonomy paragraphs.** `AGENTS.md:84` pins the `lfg` autopilot and workflow-required-step paragraphs as a two-line-apart pair compared verbatim by `.ci/test-agent-instructions.sh`; nothing may land between them. The chosen slot groups this paragraph with the file's other `ce-plan`/`ce-brainstorm`-specific override paragraphs (learnings-researcher, model elevation) and sits well clear of that anchor. Rejected: appending after the workflow-required-step-rule paragraph — works too, but separates the paragraph from its closest siblings for no benefit.

This did not qualify for a Bake-off (Phase 1.6): the issue names two candidate mechanisms, but KTD1 resolves the choice from direct repository precedent and the issue's own stated cost difference, not from a judgment call needing further development — and reversing it later (adding an overlay if the paragraph proves insufficient) is cheap, not a costly-to-reverse data shape or interface choice.

### Assumptions

- The run is unattended (`lfg`); no product or design choice this change raises needs a live user, so nothing routes through an `ask`.
- No decision was carried in as settled from the invoking conversation; every KTD above is decided in this planning pass from repository evidence.
- `ce-doc-review`'s own defer-to-Open-Questions review routing (`bulk-preview.md`, `decision-primer.md`) is unaffected beyond the general "resolve what the run can resolve" framing already in R1 — no upstream Compound Engineering file is modified by this plan.

### System-Wide Impact

`home/.chezmoitemplates/agents-instructions.tmpl` renders into all three managed harnesses' user-scoped instruction files on the next `chezmoi apply` (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.omp/agent/AGENTS.md`). The change is additive prose with no data, schema, or runtime impact, and does not touch the separate orchestration-payload render tree (`orchestration-everyone.tmpl`, `orchestration-coordinator.tmpl`).

### Risks & Dependencies

- A sibling in-flight change (issue #561) also edits `home/.chezmoitemplates/agents-instructions.tmpl`, in the "Branches, commits, issues, blockers" review-findings paragraph — a different location from this plan's insertion point in "Routing and mirrors." Mitigation: keep the diff to the one new paragraph at the planned location; fetch and refresh against `origin/main` before merging, per the standard branch-refresh rule, if it moved.

## Implementation Units

### U1. Add the "resolve, never defer" paragraph to the shared instruction core

- **Goal:** `ce-brainstorm`, `ce-plan`, and `ce-doc-review` get one dedicated, correctly-scoped override paragraph in `home/.chezmoitemplates/agents-instructions.tmpl`.
- **Requirements:** R1, R2, R3, R4, R5, R6 (KTD1, KTD2, KTD3)
- **Files:** `home/.chezmoitemplates/agents-instructions.tmpl`
- **Approach:** Insert one new paragraph in the "## Routing and mirrors" section, immediately after the existing `Compound Engineering's learnings-researcher is dispatched only for a Deep run...` paragraph and before the `{{ if eq .ctx.chezmoi.os "linux" -}}` block. Name `ce-brainstorm`, `ce-plan`, and `ce-doc-review`; state the MUST/MUST NOT resolve-vs-defer rule (R1); state the Implementation Unit fallback for a question that needs work to answer (R2); state the human-present-vs-unattended split for a genuinely user-owned choice (R3); explicitly carve out execution-time `Deferred to Implementation` (R4) and `Deferred to Follow-Up Work`/`Outside this product's identity` (R5) so the paragraph cannot be read as banning those legitimate buckets; cite the file's own precedence rule for the override authority.

  *Directional wording* (the implementer may refine phrasing; this draft was checked against `.ci/test-agent-instructions.sh`'s BANNED-phrase and needle lists so a fresh draft does not have to re-derive that clearance):

  > `ce-brainstorm`, `ce-plan`, and `ce-doc-review` MUST resolve an in-scope open question during their own run. They MUST NOT write it to Outstanding Questions, Open Questions, `Resolve Before Planning`, `Deferred to Planning`, or a `Deferred to Implementation` entry the run could settle now; this overrides those skills' own deferral sections, by the precedence rule above. Settle the question from repository evidence, research, or a stated assumption, and record the resolution as a Key Technical Decision or a `Resolved During Planning` entry. When settling it needs work, add an Implementation Unit or a requirement for that work instead of a `Deferred to Follow-Up Work` or `Deferred to Implementation` entry. Only a product, design, or requirements choice the run cannot derive stays open: ask it when a human is present, or record a default as an explicit assumption when none is. A genuinely execution-time unknown — an answer that needs code changes, runtime behavior, or execution-time discovery — still goes to `Deferred to Implementation`; that use of the bucket stays. `Outside this product's identity`, a true non-goal, and tangential work outside the confirmed scope stay exclusions under `Deferred to Follow-Up Work`, never a place to park an unresolved in-scope question.
- **Test Scenarios:**
  - Render the three wrapper templates (`dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`) via `chezmoi execute-template` against the scratch harness `AGENTS.md`'s Verification section describes; the new paragraph's text appears once, identically, in all three, outside the sanctioned per-harness paragraphs.
  - `.ci/test-agent-instructions.sh` passes: the `lfg`/workflow-required-step fixture anchor still measures exactly two lines apart, every existing needle still matches, and no BANNED phrase is present.
  - `git diff --check` and `git status` show only the intended single-paragraph addition to `home/.chezmoitemplates/agents-instructions.tmpl`.
- **Verification:** `.ci/test-agent-instructions.sh`; the scratch `chezmoi execute-template` render from `AGENTS.md`'s Verification section.

## Verification Contract

| Command | Applicability | Notes |
|---|---|---|
| `.ci/test-agent-instructions.sh` | Always | Repo's own gate for this file; run from repo root with `chezmoi` on `PATH` |
| Scratch `chezmoi execute-template` render (per `AGENTS.md` "Verification") | Always | Confirms all three harness targets render the new paragraph identically; never touches `$HOME` |
| `git diff --check` | Always | No whitespace errors in the diff |

Acceptance criteria 1-3 of issue #562 describe the future runtime behavior of `ce-brainstorm`/`ce-plan` runs under the new instruction; no automated test in this repository can invoke those upstream skills and assert their behavior, so those criteria are verified by the paragraph's text (R1-R5) and by this plan's own compliance as a worked example (it carries no Open Questions and resolved its one candidate-mechanism fork as a KTD), not by a CI check. This is a verification-method note, not an open item.

## Definition of Done

- The new paragraph is present, worded per U1, and renders identically into all three harness targets.
- `.ci/test-agent-instructions.sh` passes locally.
- No other paragraph in `agents-instructions.tmpl` changed; the `lfg` autopilot and workflow-required-step paragraphs remain exactly two lines apart.
- PR opened, CI green, PR merged, with `Closes #562` in the PR body.
- No `Unapplied review findings` remain in the PR description or the run's final report.
