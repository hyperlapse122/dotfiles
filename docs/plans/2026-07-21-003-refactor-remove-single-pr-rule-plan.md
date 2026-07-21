---
title: "refactor: remove single-PR delivery rule"
type: refactor
date: 2026-07-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: https://github.com/hyperlapse122/dotfiles/issues/63
---

# Goal Capsule

Remove the shared instruction that forces every task or issue into one branch and one MR/PR, restoring flexibility for independently reviewable delivery while preserving all unrelated branch, naming, commit, and CI safeguards.

## Summary

The shared rule has been compacted since issue #63 was written: it is now the final two sentences of the `Branches, commits, issues, blockers` paragraph rather than a standalone section. Delete only those sentences from the canonical core. The four wrapper templates remain unchanged because they include that core verbatim.

## Problem Frame

The current instruction forbids splitting large work into reviewable stacked or sequential changes. This blanket restriction can make reviews larger and riskier. The change is instruction-only and must not weaken adjacent worktree, branch-naming, commit, or CI requirements.

## Requirements

- **R1:** Remove the one-task/issue-to-one-branch-and-one-MR/PR requirement and its prohibition on sibling, phased, stacked, or sequential delivery.
- **R2:** Remove the associated prohibition on phase-shaped issue bodies and the mandate that later work always become a separate issue.
- **R3:** Preserve every unrelated rule in the shared instruction core, especially branch/worktree ownership, Git-Flow naming, commit, and CI rules.
- **R4:** Keep the four wrapper templates as bare verbatim includes of the canonical shared core.
- **R5:** Verify the managed shared target and all four rendered wrapper targets no longer contain the removed policy.

## Scope Boundaries

In scope is `dot_agents/readonly_AGENTS.md` and isolated render verification of its consumers. Wrapper edits, live `chezmoi apply`, historical plan rewrites, and changes to other branch or delivery rules are out of scope.

## Key Technical Decisions

- **KTD1 — Edit the compacted sentences, not the stale heading.** Issue #63 describes an older standalone section, but the current source contains the same policy as two sentences in a consolidated paragraph. Removing those exact sentences satisfies the requested behavior without deleting adjacent safeguards.
- **KTD2 — Preserve the include topology.** The canonical file remains the only edited instruction source; all wrapper targets inherit it through their existing one-line includes.
- **KTD3 — Verify in an isolated chezmoi destination.** Rendering uses `--source "$PWD"`, an empty config, task-scoped user cache, and a stub `op`; it never applies into live `$HOME`.

## Implementation Units

### U1 — Remove and verify the shared delivery policy

**Goal:** Delete only the obsolete delivery-policy sentences and prove every consumer inherits the updated core.

**Requirements:** R1, R2, R3, R4, R5; KTD1, KTD2, KTD3.

**Dependencies:** None.

**Files:**

- Modify `dot_agents/readonly_AGENTS.md`.
- Verify unchanged includes in `dot_claude/readonly_CLAUDE.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_config/opencode/readonly_AGENTS.md.tmpl`, and `dot_pi/agent/private_readonly_AGENTS.md.tmpl`.

**Approach:** Remove the two final delivery-policy sentences from the consolidated branches paragraph without reflowing or altering its preceding rules. Render each wrapper independently and compare the policy absence across the canonical managed file and all wrapper outputs.

**Execution note:** This is an instruction-source change; prefer isolated render and textual contract checks over unit tests.

**Patterns to follow:** The shared-core ownership documented in `AGENTS.md` and the bare include pattern in the four wrapper templates.

**Test scenarios:**

1. Search the canonical core and isolated wrapper renders for narrowly anchored removed clauses such as `One task/issue = one branch`, `split delivery into phases/stacked MRs`, and `Issue bodies MUST NOT present sequential`; expect no matches without treating unrelated uses of words such as `sibling` as failures.
2. Compare each rendered wrapper with the updated canonical core; expect verbatim equivalent content.
3. Inspect the source diff; expect only the requested two sentences removed and all preceding branch/worktree/naming rules unchanged.
4. Confirm each wrapper remains a one-line include and root `CLAUDE.md` remains exactly `@AGENTS.md`.

**Verification:** All five managed/rendered instruction surfaces omit the policy, wrapper sources are unchanged, isolated rendering succeeds, `git diff --check` passes, and the scope-limited diff contains no unrelated edits.

## Verification Contract

- Render all four wrapper templates through `chezmoi execute-template` using the repository source and a task-scoped isolated destination.
- Assert removed phrases are absent from the canonical source and rendered outputs.
- Confirm wrapper includes and the root `CLAUDE.md` mirror remain unchanged and valid.
- Run repository hygiene checks: `git diff --check`, `git status --short`, and a diff limited to `dot_agents/readonly_AGENTS.md` plus this plan.

## Risks & Dependencies

- The primary risk is over-deleting the consolidated paragraph and weakening unrelated branch safeguards; a surgical diff and explicit preservation check mitigate it.
- Historical plans may quote the old policy. They are records of prior work, not active shared-core or wrapper references, and remain unchanged.
- Local `chezmoi` rendering is required for full verification; if unavailable, CI render artifacts must be used and the limitation disclosed.

## Definition of Done

- R1–R5 are satisfied.
- The canonical source no longer contains either delivery-policy sentence.
- The shared managed target and four isolated wrapper renders no longer contain the rule.
- No wrapper, deployed home file, historical plan, or unrelated policy is modified.
- Required repository checks pass and the change is ready for review.

## Sources & Research

- GitHub issue #63 supplies the requested behavior and acceptance criteria.
- Repository inspection confirms the current compacted sentence location and the four verbatim include consumers.
- `docs/plans/2026-07-20-004-refactor-compact-agent-instructions-plan.md` documents the shared-core topology; no `docs/solutions/` or `CONCEPTS.md` corpus exists.
