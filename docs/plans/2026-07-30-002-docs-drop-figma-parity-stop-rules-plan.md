---
title: Drop Figma Parity-Diff and STOP Rules - Plan
type: docs
date: 2026-07-30
topic: drop-figma-parity-stop-rules
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Drop Figma Parity-Diff and STOP Rules - Plan

## Goal Capsule

- **Objective:** Reduce the Figma rule in the shared user-scoped agent instruction core to the MCP routing mandate alone, deleting the parity-diff verification clause and the `unavailable MCP means STOP` clause.
- **Product authority:** The user's blocking-question selection this session governs which clauses go. `.chezmoitemplates/agents-instructions.tmpl` owns the rule; six harness wrappers render it, so one edit reaches every agent surface.
- **Open blockers:** None.

## Product Contract

### Summary

The Figma rule is one sentence with three clauses: an MCP routing mandate, a parity-diff verification obligation, and a STOP-on-unavailable rule. The user wants only the routing mandate to survive. The sentence becomes ``Figma URLs MUST use the `figma` MCP.`` and nothing else in the file changes.

### Problem Frame

- At `HEAD`, `.chezmoitemplates/agents-instructions.tmpl:60` reads: ``Figma URLs MUST use the `figma` MCP; re-fetch each mentioned node and diff it before claiming parity; unavailable MCP means STOP.`` The working tree already carries the reduced one-clause form (A1), so that is the pre-edit text this plan removes, not the state an implementer will find on disk.
- Clause 2 imposes a per-node re-fetch-and-diff verification obligation on every Figma task. Clause 3 dictates what an agent does when the MCP is unreachable.
- The user judges both surplus to the routing mandate they want to keep. This is a deliberate reduction of the instruction contract, not a correction of a wrong rule.
- The sentence shares its paragraph with unrelated tmux/Playwright guidance, so the edit must be clause-scoped, not paragraph-scoped.

### Requirements

- R1. The Figma sentence MUST read exactly ``Figma URLs MUST use the `figma` MCP.`` — the routing mandate and nothing more.
- R2. The parity-diff verification clause MUST be absent from every harness render.
- R3. The `unavailable MCP means STOP` clause MUST be absent from every harness render.
- R4. Nothing else in the file changes: the `## Figma, processes, scratch, and browser` heading, the tmux and Playwright sentences in the same paragraph, and all six harness conditionals stay byte-identical.

### Scope Boundaries

**In scope**

- Two clauses removed from one sentence in `.chezmoitemplates/agents-instructions.tmpl`.

**Non-goals**

- The section heading. It still names Figma correctly because the routing mandate survives (KTD2).
- A replacement rule for MCP unavailability. Removing the STOP clause leaves that behavior unspecified by design (KTD3).
- The root `AGENTS.md` supplement, which never restated this rule, and the `figma-auth` utility, its build script, its package, and the `figma` MCP declaration in `.chezmoidata/agents.yaml` — all untouched.
- Any deployed `$HOME` instruction target. No `chezmoi apply` runs.

### Acceptance Examples

- AE1. **Covers R1, R2, R3.** Rendering any of the six harness wrappers yields the one-clause Figma sentence, and searching each render for `claiming parity` and `unavailable MCP` returns nothing.
- AE2. **Covers R4.** Each render differs from its deployed counterpart only by that sentence.
- AE3. **Covers R4.** The opencode, pi, and omp renders still differ from the claude, codex, and agy renders, proving the three harness conditionals survived the edit.

## Key Technical Decisions

- **KTD1 — Delete both the verification and the STOP clause; keep the routing mandate.** *(session-settled: user-directed — chosen over deleting only the verification clause, and over deleting the whole Figma sentence with a heading rename: the user wants the `figma` MCP routing mandate preserved, but no verification obligation and no prescribed unavailability behavior.)*
- **KTD2 — Keep the `## Figma, processes, scratch, and browser` heading.** The retained mandate still names Figma, so the heading remains accurate; renaming it would churn a line the settled decision does not reach and would make the heading undersell its content.
- **KTD3 — Accept both residual gaps rather than backfilling a softer substitute.** The two deleted clauses are not equally backstopped, so name them separately. **Unavailability** falls through to the file's existing general rule at `.chezmoitemplates/agents-instructions.tmpl:56` — "A confirmed tooling/access/destructive/product blocker MUST be surfaced with evidence, a proposed path, and an explicit ask, then wait" — which this change does not touch; an unreachable or unauthenticated `figma` MCP is such a blocker, so the residual is discoverability (the agent must generalize it itself, with no local cross-reference) rather than a behavioral void. The retained MUST also names exactly one compliant path, so there is no rules-compliant way to route around the MCP. **Parity claims** have no equivalent backstop: the deleted clause was the file's only obligation to re-fetch before asserting a design matches, and nothing surviving forces that, so an agent may answer a parity question from stale context. Both are accepted; writing a replacement ("note the gap and continue") would introduce product behavior this session did not settle. Note the divergence for whoever revisits this: lines 25, 26, and 28 each restate STOP locally even though line 56 would cover them, so this rule is now the only failure-adjacent one relying purely on the general fallback. `figma-auth` remains the on-demand authorization path, unaffected.
- **KTD4 — No downstream document edits.** The root `AGENTS.md` never restated the rule. `docs/plans/2026-07-20-001-feat-figma-mcp-auth-utility-plan.md` cites only the surviving "MUST use the `figma` MCP" clause as `figma-auth`'s authority, so no historical plan is invalidated by the deletion.

## Assumptions

- A1. The source edit is already applied in the working tree, uncommitted, from the invoking conversation. U1 is verify-and-land, not a fresh edit.
- A2. No automated check asserts the instruction body text — `.ci/` holds no instruction-content test — so render equality plus a targeted absence search is the only mechanical gate available.

## Implementation Units

### U1. Reduce the Figma rule to the routing mandate

- **Goal:** The Figma sentence carries only the MCP routing mandate.
- **Requirements:** R1, R2, R3, R4. Implements KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the Figma sentence opening the paragraph under `## Figma, processes, scratch, and browser`.
- **Approach:** Confirm the sentence in the working tree already reads the single mandate clause terminated by a period, with the heading, the two following sentences in the same paragraph, and every `{{ if eq .harness ... }}` island untouched, and the retained clause keeping its existing inline-code token style for `figma`. Re-derive that state only if the working tree does not match — the replacement drops the semicolon-joined second and third clauses and nothing else.
- **Execution note:** Verify-and-land, not a fresh edit (A1): the clause-scoped reduction is already applied, so the work is proving it against the Verification Contract and committing it. Read the whole paragraph before touching anything, and confirm the sentence boundary so the tmux sentence that follows is neither absorbed nor reflowed.
- **Patterns to follow:** The compact RFC-2119 clause style used throughout the same file; the prose-edit verification contract established by `docs/plans/2026-07-29-004-docs-per-issue-closing-keywords-plan.md` for this exact template.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A2).` Proven by the Verification Contract below.
- **Verification:** All six harness wrappers render without a template error; each render carries the one-clause sentence exactly once; neither deleted phrase appears in any render.

## Verification Contract

- **Render check.** Render all six wrappers — `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_gemini/readonly_GEMINI.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`, `dot_pi/private_agent/private_readonly_AGENTS.md.tmpl` — with `chezmoi execute-template --source "$PWD"`, a stub `op`, an empty config, and a throwaway destination per the repository verification rules. The template is a `.chezmoitemplates` partial, not a target, so it is compared as rendered text on both sides.
- **Absence check.** Search every render for `claiming parity` and `unavailable MCP`; both MUST return zero matches (AE1).
- **Baseline check.** Compare each render against its already-deployed counterpart (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.omp/agent/AGENTS.md`, `~/.pi/agent/AGENTS.md`) read-only; the only difference MUST be the Figma sentence (AE2).
- **Harness-variance check.** The opencode, pi, and omp renders MUST still differ from the claude, codex, and agy renders (AE3).
- **Source-delta check.** `git diff --word-diff` on the template shows only the two clauses removed plus the sentence-terminating period — no reflow of surrounding clauses (R4).
- **Scope check.** `git status` and the diff show only `.chezmoitemplates/agents-instructions.tmpl` and this plan changed. No deployed `$HOME` target is written and no `chezmoi apply` runs.
- **Branch check.** The working branch carries a work-descriptive Git-Flow slug before the first push — not the aoe worktree name `slavs` — and the rename happened in place while the branch was still absent from the remote.
- **CI.** `ci.yml` triggers on any push and on pull requests. `render-dotfiles.yml` triggers on push to `main`, on pull requests (`opened`, `reopened`, `synchronize`), and on `workflow_dispatch`, so it first fires when the PR opens. Both MUST reach terminal success on the pull request.

## Definition of Done

- The Figma sentence satisfies R1, and both deleted clauses are absent from all six renders.
- Each render differs from its deployed counterpart only by that sentence.
- The branch is renamed in place to a work-descriptive Git-Flow slug before the first push. The current `slavs` is an aoe worktree name, is absent from the remote, and `HEAD` equals `origin/main`, so the rename is safe and the PR carries only this change.
- One lowercase Conventional Commit lands the change; a PR is open; `ci.yml` and `render-dotfiles.yml` are both green on it.

## Open Questions

- None blocking. Two accepted residual risks, tracked separately per KTD3. (a) **Figma-unavailability guidance** is deliberately left to the general blocker rule at `.chezmoitemplates/agents-instructions.tmpl:56`; revisit only if an agent is observed producing Figma work with no MCP access and no signal to the user. (b) **No re-fetch obligation before a parity claim** — the genuinely unbackstopped gap; revisit if an agent is observed asserting a design matches Figma from stale context rather than a fresh fetch. These are distinct failure modes with different blast radii, so neither should be folded into the other.

## Sources / Research

- `.chezmoitemplates/agents-instructions.tmpl:58-60` — the heading and the three-clause sentence being reduced.
- The six harness wrappers, each a one-line `includeTemplate "agents-instructions.tmpl" (dict "harness" "<id>")` call — the fan-out that makes one edit reach every surface.
- `docs/plans/2026-07-29-004-docs-per-issue-closing-keywords-plan.md` — prior art for a prose edit to this same template, including the render-equality verification contract reused here.
- `docs/plans/2026-07-20-001-feat-figma-mcp-auth-utility-plan.md:17` — cites the surviving "MUST use the `figma` MCP" clause as `figma-auth`'s authority; unaffected by this change (KTD4).
- `.chezmoidata/agents.yaml:99-102` — the `figma` MCP server declaration (`http`, `oauth`), untouched.
- `.github/workflows/ci.yml:3-5` and `.github/workflows/render-dotfiles.yml:34-39` — the trigger sets asserted in the Verification Contract.
- User selection this session (authoritative): delete the verification and STOP clauses, keep the MCP routing mandate.
