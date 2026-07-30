---
title: Route Review Findings to MR Fix or Tracker Issue - Plan
type: docs
date: 2026-07-30
topic: route-review-findings-to-mr-or-issue
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Route Review Findings to MR Fix or Tracker Issue - Plan

## Goal Capsule

- **Objective:** Make every actionable code-review finding end a run either fixed in the MR/PR under review or filed as a tracker issue. Remove the current outcome where a committed markdown record is the only durable artifact.
- **Product authority:** The user's instruction this session. `.chezmoitemplates/agents-instructions.tmpl` owns both edited paragraphs; six harness wrappers render it, so one edit reaches every agent surface.
- **Execution profile:** Two prose edits to one shared template, then a user-authorized `chezmoi apply` so the six deployed instruction targets carry the new text.
- **Open blockers:** None.

---

## Product Contract

### Summary

One clause in the shared instruction core forbids issue creation outright. That clause, not the `lfg` pipeline, is why review findings land in a committed markdown file instead of the tracker: `lfg` step 6 already tries the tracker first and falls back to a record file only when no sink exists. Narrowing the prohibition and adding an explicit two-state routing rule produces the wanted behavior with no pipeline change.

### Problem Frame

- `.chezmoitemplates/agents-instructions.tmpl:54` reads, in part: "the agent SHOULD link it and track it, and MUST NOT create issues or manage labels, milestones, or other people's assignees." The blanket `MUST NOT create issues` forces `lfg`'s residual handoff down its `no_sink` path.
- Observed effect: on telerad-frontend MR !366 the residual findings became a committed record file only. A markdown file in the repository is not a tracked work item; nobody triages it.
- `ce-code-review` already draws the actionable boundary this rule needs. Its actionable queue is `gated_auto` or `manual` with owner `downstream-resolver`; `advisory` is report-only. Reusing that boundary avoids inventing a second classification.
- Nothing in the instruction core states what must happen to a finding the current MR does not fix, so "write it down somewhere" currently satisfies the rules.
- The two target paragraphs sit in the common (unconditional) region of the template. Three `{{ if eq .harness ... }}` islands exist elsewhere in the file and must not be disturbed.

### Requirements

- R1. The blanket `MUST NOT create issues` prohibition MUST be narrowed. Issue creation is permitted for exactly one purpose: routing an actionable review finding that the current MR/PR does not fix.
- R2. Issue creation for any other purpose MUST remain prohibited.
- R3. Before filing, the agent MUST search the project's existing open issues and MUST NOT create a duplicate.
- R4. The prohibitions on managing labels, milestones, and other people's assignees MUST survive verbatim in meaning.
- R5. In a repository with a declared tracker, an actionable review finding MUST end a run in exactly one of two states: fixed in the MR/PR under review, or filed as a tracker issue. The no-declared-tracker case in R9 is the one exception, and it is the only permitted record-only outcome.
- R6. A committed markdown record MAY supplement a filed issue and MUST NOT replace it.
- R7. Advisory / FYI observations MUST be exempt, using the review's own actionable-versus-advisory classification rather than a new one.
- R8. A filed issue MUST carry evidence (`file:line` plus the verbatim quoted finding), severity, and a link to the originating MR/PR.
- R9. Filing MUST be gated on a tracker the project declares and approves for this purpose. With no such declaration, the run falls back to the committed record file plus a report to the user. The gate is resolved by agent judgment over the project's own declarations, not by a dedicated machine-readable approval field.
- R10. These items MUST remain unchanged: the `Closes #N` / `Refs #N` rules, the prohibition on direct issue close/reopen, the self-assignment exception, and every `{{ if eq .harness ... }}` block.
- R11. All six deployed instruction targets MUST carry the new text, and none may still carry the old blanket prohibition.

### Scope Boundaries

**In scope**

- One clause rewritten at `.chezmoitemplates/agents-instructions.tmpl:54`.
- Sentences added to the paragraph at `.chezmoitemplates/agents-instructions.tmpl:56`, anchored after "A task is complete only when every criterion is implemented and verified."
- A user-authorized `chezmoi apply` that deploys the six rendered instruction targets.

**Non-goals**

- The `lfg` skill, `ce-code-review`, and `tracker-defer.md`. They already implement tracker-first routing; the instruction core was the blocker.
- The root `AGENTS.md` supplement. It never restated this rule and may not weaken the core.
- Any project-level `AGENTS.md`. The core forbids a project file from relaxing a core `MUST NOT`, so a project-level fix would be a rule violation.
- telerad-frontend's `docs/residual-review-findings/feature-requester-header-save-draft.md`. Its "not filed as an issue" sentence is stale relative to the already-filed #195, but it belongs to another repository.
- Creating a `.compound-engineering/config.local.yaml` in this repository. The gate reads such a file where one exists; it does not require one here.

### Acceptance Examples

- AE1. **Covers R1, R2, R3, R11.** Every one of the six renders contains the narrowed permission and the duplicate-search duty, and searching each render for `MUST NOT create issues` returns nothing.
- AE2. **Covers R4, R10.** Every render still forbids managing labels, milestones, and other people's assignees; still forbids direct issue close/reopen; still carries the self-assignment exception and the full `Closes #N` / `Refs #N` chain.
- AE3. **Covers R5, R6, R7, R8, R9.** Every render states the two-state outcome, its named no-tracker exception, the supplement-not-replace rule, the advisory exemption, the required issue contents, and the declared-tracker gate.
- AE4. **Covers R10.** The opencode, pi, and omp renders still differ from the claude, codex, and agy renders, proving the harness conditionals survived.
- AE5. **Covers R11.** After apply, all six deployed targets match their renders.

---

## Key Technical Decisions

- **KTD1 — Narrow the prohibition; do not delete it.** *(session-settled: user-directed — chosen over deleting the `MUST NOT create issues` clause entirely: an unrestricted permission would let agents open issues for any reason. The permission is scoped to one purpose and paired with a duplicate search.)*
- **KTD2 — Gate filing on a tracker the project declares and approves.** *(session-settled: user-directed — chosen over filing in every repository: an ungated default would accumulate bot issues in forks and third-party checkouts. With no declaration, the existing record-file fallback stands.)* The user flagged this as the reversible decision; removing one sentence makes filing unconditional. **The gate is agent judgment, not a lookup.** No dedicated approval field exists for this purpose: `tracker-defer.md` derives its sink from `{ tracker_name, confidence, named_sink_available, any_sink_available }` via instructions-in-context plus live probes, and the `feedback_sources[].approved: true` entry in `.compound-engineering/config.local.yaml` is a `ce-sweep` feedback-triage declaration, not a code-review filing permission. The instruction text therefore MUST read as a judgment gate over whichever declaration the project actually carries — an instruction file naming the tracker, or that config declaring one — and MUST NOT imply a field the toolchain reads. This is coherent because `tracker-defer.md`'s own detection step consults the project instructions already in the agent's context, which is exactly the surface this rule governs.
- **KTD3 — Reuse `ce-code-review`'s actionable boundary instead of defining a new one.** *(session-settled: user-directed.)* Its schema fixes `autofix_class` to `gated_auto` / `manual` / `advisory` and `owner` to `downstream-resolver` / `human` / `release`, with the actionable queue being `gated_auto` or `manual` plus `downstream-resolver`. The instruction text names the general boundary first and cites those tokens as the concrete instance, so the rule still reads correctly for a review that did not come from that skill.
- **KTD4 — Put the routing rule in the completion paragraph, not the issue-lifecycle paragraph.** The user named the anchor sentence, and the rule is a completion obligation of the same family as the CI-green and no-silent-deferral rules that already live there. The issue-lifecycle paragraph keeps the permission and the duplicate-search duty, which are about issue mechanics.
- **KTD5 — Deploy with the narrowest apply that satisfies R11.** Run `chezmoi diff --source "$PWD"` first. If the pending change set is only the six instruction targets, run a full `chezmoi apply --source "$PWD"`. If it also queues unrelated script reruns, apply the six targets by path instead and report what was skipped. The repository warns that an `install-system-30-network` rerun must happen from a local console, so a blind full apply is not acceptable without reading the diff first.
- **KTD6 — Apply from this worktree with `--source "$PWD"`.** Nested worktrees cause recursive source-state errors without it, and `HEAD` here equals `origin/main`, so the only delta reaching `$HOME` is this change.

---

## Assumptions

- A1. The user's explicit request to run `chezmoi apply` is the authorization the repository rules require for touching deployed `$HOME` targets. Without that request the default remains source-only.
- A2. No automated check asserts instruction body text — `.ci/` holds no instruction-content test — so render comparison plus targeted phrase searches are the available mechanical gates.
- A3. The current branch `mongols` is an aoe worktree name, is absent from the remote, and must be renamed in place to a work-descriptive Git-Flow slug before the first push.

---

## Implementation Units

### U1. Narrow the issue-creation prohibition

- **Goal:** Issue creation is permitted only to route an actionable review finding the current MR/PR does not fix, and only after a duplicate search.
- **Requirements:** R1, R2, R3, R4. Implements KTD1.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the clause `and MUST NOT create issues or manage labels, milestones, or other people's assignees.` in the issue-lifecycle paragraph under `## Branches, commits, issues, blockers`.
- **Approach:** Replace only that clause. The label / milestone / other-people's-assignee prohibition stays. Add the scoped permission, an explicit restatement that other-purpose issue creation stays prohibited, and the duplicate-search duty. Keep the sentence chain that follows — self-assignment, task-list ticking, key-event commenting, closure keywords — byte-identical.
- **Execution note:** Prose edit to a shared instruction contract. Read the whole paragraph before editing and confirm the clause boundary, so the self-assignment sentence that follows is neither absorbed nor reflowed.
- **Patterns to follow:** The compact RFC-2119 clause style used throughout the same file; the prose-edit approach in `docs/plans/2026-07-29-004-docs-per-issue-closing-keywords-plan.md`, which edits this same paragraph.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A2).` Proven by the Verification Contract.
- **Verification:** All six wrappers render without a template error. No render contains `MUST NOT create issues`. Every render carries the duplicate-search duty (R3) and still forbids managing labels, milestones, and other people's assignees.

### U2. Add the two-state findings routing rule

- **Goal:** The instruction core states that an actionable review finding ends fixed in the MR/PR or filed as a tracker issue, never as a record file alone.
- **Requirements:** R5, R6, R7, R8, R9. Implements KTD2, KTD3, KTD4.
- **Dependencies:** U1 (the permission U1 grants is what this rule exercises; both land in one commit).
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the paragraph containing "A task is complete only when every criterion is implemented and verified."
- **Approach:** Insert the rule inside that paragraph, immediately after the anchor sentence and before the blocker sentence, so the CI chain and the blocker chain stay intact. The rule states: the two permitted end states; that a committed markdown record supplements but never replaces a filed issue; the advisory exemption expressed as the review's own actionable-versus-advisory boundary with the `gated_auto` / `manual` / `downstream-resolver` versus `advisory` tokens cited as the concrete instance; the required issue contents (`file:line` plus verbatim quote, severity, originating MR/PR link); and the declared-tracker gate. The gate sentence MUST name the no-tracker fallback as the single exception to the two-state rule, so the record-file path reads as a bounded exception rather than a third default (R5, R9).
- **Execution note:** Keep each sentence to one idea, active voice, RFC-2119 terms used literally — the file's own writing rule applies to itself.
- **Patterns to follow:** The obligation-then-exception sentence shape already used in this paragraph ("never poll, weaken, skip …"); the inline-code token style used elsewhere in the file for identifiers.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template with no automated content assertion (A2).` Proven by the Verification Contract.
- **Verification:** Every render carries all five obligations, and the no-tracker fallback reads as an explicit exception to the two-state rule. The `Closes #N` / `Refs #N` chain, the close/reopen prohibition, and the self-assignment exception are unchanged.

### U3. Deploy and verify the six instruction targets

- **Goal:** All six deployed instruction targets carry the new text; none carries the old prohibition.
- **Requirements:** R11. Implements KTD5, KTD6.
- **Dependencies:** U1, U2.
- **Files:** No source file changes. Deployed targets: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.pi/agent/AGENTS.md`, `~/.omp/agent/AGENTS.md`.
- **Approach:** Run `chezmoi diff --source "$PWD"` and read the whole pending change set before writing anything. Apply per KTD5 — full apply when the change set is only the six targets, targeted apply otherwise. Then grep each deployed target for the new phrases and for the removed one.
- **Execution note:** This unit writes to the real `$HOME`, authorized by A1. Read the diff before applying; do not apply blind. Report any script rerun the diff reveals.
- **Patterns to follow:** The repository verification recipe — `--source "$PWD"`, stub `op`, empty config, per-user scratch — for the read-only render checks that precede the apply.
- **Test scenarios:** `Test expectation: none — deployment step; proven by post-apply content assertions in the Verification Contract.`
- **Verification:** Each of the six deployed targets contains the narrowed permission and the routing rule, and none contains `MUST NOT create issues`.

---

## Verification Contract

- **Render check.** Render all six wrappers — `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_gemini/readonly_GEMINI.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`, `dot_pi/private_agent/private_readonly_AGENTS.md.tmpl` — with `chezmoi execute-template --source "$PWD"`, a stub `op`, an empty config, and a throwaway destination. The edited file is a `.chezmoitemplates` partial, not a target, so it is compared as rendered text.
- **Absence check.** Search every render for `MUST NOT create issues`; zero matches required (AE1).
- **Presence check.** Search every render for the narrowed permission, the duplicate-search duty, the two-state rule, its named no-tracker exception, the supplement-not-replace rule, the advisory exemption, the issue-contents requirement, and the tracker gate (AE1, AE3).
- **Preservation check.** Search every render for the label/milestone/assignee prohibition, `MUST NOT run a direct issue close or reopen`, the self-assignment exception, and `Closes #1, Closes #2, Closes #3` (AE2).
- **Harness-variance check.** The opencode, pi, and omp renders still differ from the claude, codex, and agy renders (AE4).
- **Source-delta check.** `git diff --word-diff` on the template shows only the intended clause replacement and the inserted sentences — no reflow of surrounding clauses.
- **Deployment check.** After apply, each of the six deployed targets satisfies the absence, presence, and preservation checks (AE5).
- **Scope check.** `git status` and the diff show only `.chezmoitemplates/agents-instructions.tmpl` and this plan changed.
- **Branch check.** The branch carries a work-descriptive Git-Flow slug before the first push — not the aoe worktree name `mongols` — renamed in place while absent from the remote (A3).
- **CI.** `ci.yml` triggers on any push and on pull requests; `render-dotfiles.yml` triggers on push to `main`, on pull requests, and on `workflow_dispatch`, so it first fires when the PR opens. Both MUST reach terminal success on the pull request.

---

## Definition of Done

- `.chezmoitemplates/agents-instructions.tmpl` satisfies R1-R10.
- All six renders and all six deployed targets satisfy the absence, presence, and preservation checks (R11).
- The branch is renamed in place to a work-descriptive Git-Flow slug before the first push.
- One lowercase Conventional Commit with a `docs(agents):` subject lands the change; a PR is open; `ci.yml` and `render-dotfiles.yml` are green on it.

---

## Open Questions

- None blocking. One deliberate, reversible choice is recorded as KTD2: filing is gated on a declared approved tracker. Deleting that one gate sentence makes filing unconditional in every repository.

---

## Sources / Research

- `.chezmoitemplates/agents-instructions.tmpl:54` — the blanket prohibition being narrowed; `:56` — the completion paragraph receiving the routing rule.
- The six harness wrappers, each a one-line `includeTemplate "agents-instructions.tmpl" (dict "harness" "<id>")` call — the fan-out that makes one edit reach every surface.
- `lfg` skill `references/tracker-defer.md` — the non-interactive fallback chain (named tracker, then GitHub Issues via `gh`, then the `no_sink` bucket) and the ticket-composition contract that the new evidence/severity/link requirement mirrors.
- `ce-code-review` `references/findings-schema.json` and `references/finish-review.md` — the `gated_auto` / `manual` / `advisory` enum, the `downstream-resolver` / `human` / `release` owners, and the rule that the actionable queue is `gated_auto` or `manual` plus `downstream-resolver` (KTD3).
- `.compound-engineering/config.local.yaml` in the telerad-frontend checkout — a `feedback_sources` entry of `type: gitlab-issues` with `approved: true`, the declaration shape KTD2's gate reads.
- `docs/plans/2026-07-29-004-docs-per-issue-closing-keywords-plan.md` — prior art for a prose edit to this same paragraph, including the render-comparison verification contract reused here.
- Root `AGENTS.md` — apply only on user request; `--source "$PWD"` for nested worktrees; the local-console warning for an `install-system-30-network` rerun (KTD5, KTD6, A1).
- User instruction this session (authoritative): narrow the prohibition, add the two-state rule, gate on a declared tracker, and deploy to all six targets.
