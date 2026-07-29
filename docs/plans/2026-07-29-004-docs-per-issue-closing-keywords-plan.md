---
title: Per-Issue Closing Keywords - Plan
type: docs
date: 2026-07-29
topic: per-issue-closing-keywords
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Per-Issue Closing Keywords - Plan

## Goal Capsule

- **Objective:** Require every issue an MR/PR fully resolves to carry its own closing keyword, so a multi-issue closure reads `Closes #1, Closes #2, Closes #3` and every shared-keyword form (`Closes #1, #2, #3`, `Closes #1 and #2`) is forbidden.
- **Primary driver:** GitLab. Its documentation presents a comma-separated list after one keyword as closing every referenced issue, but the form does not close reliably in practice; the repeated-keyword form does.
- **Product authority:** The common instruction core `.chezmoitemplates/agents-instructions.tmpl`, whose *Branches, commits, issues, blockers* section already owns the closure rule. Six harness wrappers include it verbatim, so one edit reaches every agent surface.
- **Open blockers:** None.

---

## Product Contract

### Summary

The closure rule in the common agent instructions currently says only *"place a closing keyword (`Closes #N`) in the MR/PR description"*. It says nothing about the multi-issue case, so an agent that resolves three issues in one MR may write the shared-keyword list `Closes #1, #2, #3` — which leaves issues open on merge. This change adds a two-sentence rule requiring one keyword per issue and naming the shared-keyword shapes as prohibited.

### Problem Frame

- The rule is silent on the multi-issue form, and the natural English shapes (`Closes #1, #2, #3`, `Closes #1 and #2`) are the failing ones.
- **Observed (user-reported, authoritative for this change):** on GitLab a shared-keyword list does not close every referenced issue reliably, even though `doc/user/project/issues/managing_issues.md` presents `Closes #4, #6` as closing both.
- On GitHub the shared form is documented as wrong: closing keywords require full syntax per issue (`Resolves #10, resolves #123`), so only the first reference links and closes.
- GitLab's closing pattern is instance-configurable (self-managed and Dedicated), so any rule that depends on the default pattern's list-continuation behavior is less portable than one keyword per issue.
- Silent failure mode: the MR merges, CI is green, the agent reports success, and the un-closed issues are only noticed later by a human.

### Requirements

- R1. When one MR/PR fully resolves several issues, the description MUST carry a closing keyword for **each** issue: `Closes #1, Closes #2, Closes #3`.
- R2. The rule MUST be a positive invariant covering every separator — each issue number is immediately preceded by its own keyword — and MUST name the shared-keyword shapes it forbids by example, both the comma list (`Closes #1, #2, #3`) and the conjunction (`Closes #1 and #2`).
- R3. The rule MUST state the reason briefly — GitHub requires the full keyword syntax per issue, and on GitLab a shared list does not close reliably in practice despite its documented comma form — so an agent does not "simplify" the repetition away as redundant prose.
- R4. The rule MUST remain tool-neutral prose in the existing closure sentence chain, valid for both `gh` and `glab`, and MUST NOT weaken the existing guards it sits beside (fully-resolves-only, unambiguous-match-only, multi-MR final-MR-only, no direct close/reopen) or read as permission to close a partly-resolved issue.

### Scope Boundaries

**In scope**

- Two sentences added to the issue-lifecycle paragraph of `.chezmoitemplates/agents-instructions.tmpl`.

**Non-goals**

- The `Refs #N` non-closing form. `Refs` is in neither platform's keyword set, and a bare `#N` mention auto-links on both, so repetition is not load-bearing there.
- The GitLab push-options paragraph (`-o merge_request.description=...` "carrying any `Closes #N` / `Refs #N`"). It references the keyword generically and stays correct; duplicating the multi-issue rule there would create a second source of truth.
- The `Closes group/project#N` cross-project form, per-platform keyword synonyms (`Fixes`, `Resolves`, `Implements`), and the repository root `AGENTS.md` supplement, which does not restate the closure rule.
- Empirically re-testing GitLab closure behavior on a live instance (see Open Questions).

### Acceptance Examples

- AE1. **Three issues, one MR.** The MR fully resolves `#1`, `#2`, `#3` → description carries `Closes #1, Closes #2, Closes #3` → on merge to the default branch, all three close. Covers R1.
- AE2. **Forbidden shapes recognized.** An agent drafting `Closes #1, #2, #3` or `Closes #1 and #2` finds both named as prohibited and rewrites them with one keyword per issue. Covers R2.
- AE3. **Mixed closure and reference.** The MR fully resolves `#1` but only partly addresses `#2` → `Closes #1, Refs #2` → only `#1` closes. Covers R1 and R4 (the fully-resolves guard still gates each keyword individually).
- AE4. **Single issue unchanged.** A one-issue MR still carries plain `Closes #42`, and no other guard in the paragraph changes behavior. Covers R4.

---

## Key Technical Decisions

- **KTD1 — Positive invariant plus named forbidden shapes.** Require that each issue number be immediately preceded by its own keyword, and name both `Closes #1, #2, #3` and `Closes #1 and #2` as prohibited. **Rationale:** a positive-only rule ("repeat the keyword") is easy to satisfy accidentally-wrong, but a prohibition keyed to one spelling is worse — GitLab's default closing pattern treats ` and ` as an equivalent list separator, so the conjunction is the same defect in different clothing and would pass a comma-only check while leaving trailing issues open on GitHub. The invariant closes the whole class; the examples keep the check mechanical.

- **KTD2 — One tool-neutral rule, appended to the existing closure sentence chain.** Insert after the multi-MR sentence and before the final "`Closes #N`/`Refs #N` are valid on both GitHub (`gh`) and GitLab (`glab`)" sentence, so the platform-validity sentence still closes the chain. **Rationale:** matches the file's compact RFC-2119 prose and the established no-per-tool-branching decision for this rule (the tokens are byte-identical on both platforms). A GitLab-only variant would fork the text and leave GitHub's stricter requirement unstated.

- **KTD3 — Carry the reason in one clause, and keep it non-falsifiable.** State GitHub's documented per-issue requirement and GitLab's unreliable-in-practice behavior, without asserting that GitLab never closes a comma list. **Rationale:** the writing baseline in this same file requires concise output, and an agent that does not know *why* the repetition matters will collapse it as redundancy — so the reason must survive. But GitLab's published default regex does match a comma list, so an absolute claim invites an agent to verify it against the docs, find it contradicted, and delete the rule. Naming the docs/practice gap explicitly pre-empts that check; the full evidence trail lives in this plan, not in every rendered agent file.

---

## Implementation Units

### U1. Add the multi-issue closing-keyword rule

- **Goal:** The closure rule requires one keyword per issue and names the shared-keyword shapes as prohibited.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` — the issue-lifecycle paragraph in `## Branches, commits, issues, blockers` (the closure sentence chain that begins "Closure is platform-driven").
- **Approach:** Insert two sentences between the existing multi-MR sentence ("When an issue spans multiple MRs, only the final, fully-resolving MR carries `Closes #N`; earlier MRs use `Refs #N`.") and the platform-validity sentence. They MUST: require, for an MR/PR that fully resolves several issues, that every issue number be immediately preceded by its own keyword, shown as `Closes #1, Closes #2, Closes #3`; forbid the shared-keyword shapes `Closes #1, #2, #3` and `Closes #1 and #2`; and give the reason (GitHub requires full keyword syntax per issue; on GitLab a shared list does not close reliably in practice despite its documented comma form), ending on the silent-failure consequence. Leave the surrounding clauses, the `Refs #N` guidance, and the GitLab push-options paragraph untouched.
- **Execution note:** Prose edit to a shared instruction contract — read the whole paragraph first and preserve clause order; the addition must not read as permission to add `Closes` for an issue the MR does not fully resolve.
- **Patterns to follow:** The existing RFC-2119 clause style in the same paragraph, and the inline-code token style (`Closes #N`, `Refs #N`) already used there.
- **Test scenarios:** `Test expectation: none — prose edit to a non-executable instruction template.` Verified by the Verification Contract below (render equality plus prose-consistency review), not by unit tests.
- **Verification:** Every harness render contains the new rule exactly once, the rest of each rendered file is byte-identical to the pre-edit render, and all six harness variants render without a template error.

---

## Verification Contract

- **Render check.** Render each harness wrapper (`dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, `dot_gemini/readonly_GEMINI.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`, `dot_pi/private_agent/private_readonly_AGENTS.md.tmpl`) with `chezmoi execute-template --source "$PWD"`, an `op` stub, an empty config, and a throwaway destination per the repository verification rules. The pre-edit baseline is the already-deployed instruction file for each harness (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.omp/agent/AGENTS.md`, `~/.pi/agent/AGENTS.md`) — read-only, never written. A `HEAD`-side render is **not** obtainable by feeding a wrapper on stdin, because `includeTemplate "agents-instructions.tmpl"` resolves from the `--source` root, so the working-tree partial would be used either way. Expect exactly one changed line per harness and the rule present exactly once.
- **Source-line delta check.** `git diff --word-diff` on `.chezmoitemplates/agents-instructions.tmpl` shows only added words — no deletion or reflow of the surrounding clauses.
- **Prose-consistency review.** Confirm the addition uses MUST/MUST NOT literally; shows `Closes #1, Closes #2, Closes #3` as required and both `Closes #1, #2, #3` and `Closes #1 and #2` as prohibited (R2); carries the GitHub/GitLab reason (R3); does not contradict the fully-resolves-only, unambiguous-match-only, multi-MR, or no-direct-close guards; and does not duplicate the push-options paragraph.
- **Scope check.** `git status` and the diff show only `.chezmoitemplates/agents-instructions.tmpl` and this plan changed. No deployed `$HOME` target is written, and no `chezmoi apply` runs.
- **CI.** `ci.yml` runs on any branch push; `render-dotfiles.yml` runs only on `push` to `main`, `pull_request`, and `workflow_dispatch`, so it first fires when the PR opens. Both MUST reach terminal success on the pull request.

## Definition of Done

- The rule is present in `.chezmoitemplates/agents-instructions.tmpl` and satisfies R1-R4.
- Each harness render differs from its deployed pre-edit counterpart only by the added rule.
- The branch is renamed to a work-descriptive Git-Flow slug before the first push (the current `saracens` is an aoe worktree name, absent from the remote).
- A PR is open and both workflows are green on it.

## Open Questions

- Which GitLab instance produced the driving observation, and is its `issue_closing_pattern` customized? Pattern override is documented for self-managed and Dedicated only, so on GitLab.com the default regex applies unchanged. This does not gate the change — the repeated-keyword form is correct under the default pattern and required on GitHub — but it would explain the deviation.
- Empirically confirming the remedy (one MR with repeated keywords closing every referenced issue on merge) needs a live instance with throwaway issues. Deliberately out of scope here; recorded so it is not mistaken for a verified claim.

## Sources / Research

- GitHub Docs, *Linking a pull request to an issue* — "Multiple issues | Use full syntax for each issue | `Resolves #10, resolves #123, resolves octo-org/octo-repo#100`". <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue>
- GitLab Docs, *Manage issues → Closing issues automatically / Default closing pattern* — presents `Closes #4, #6` as closing both, and publishes the pattern whose list separator group `(?: *,? +and +| *,? *)` makes ` and ` equivalent to `, `. <https://docs.gitlab.com/user/project/issues/managing_issues/>
- GitLab Docs, *Issue closing pattern* — the pattern is overridable on self-managed and Dedicated instances, so a form that relies on default list-matching is less portable than a repeated keyword. <https://docs.gitlab.com/administration/issue_closing_pattern/>
- User observation (this session, authoritative): on GitLab the documented comma-list form does not work reliably in practice. This is the primary driver for the rule.
- Prior art in this repo: `docs/plans/2026-07-21-004-docs-issue-lifecycle-rules-plan.md` (closure keyword rule, `Refs #N` choice, tool-neutral single-block decision) and `docs/plans/2026-07-21-005-docs-gitlab-push-options-mr-plan.md` (the push-option paragraph that references the keyword).
