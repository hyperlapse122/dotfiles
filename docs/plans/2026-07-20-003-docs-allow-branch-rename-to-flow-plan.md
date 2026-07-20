---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "docs: allow agents to rename a branch to follow project flow"
type: docs
created: 2026-07-20
---

# docs: allow agents to rename a branch to follow project flow

## Summary

Relax the shared agent-instruction core so an agent **may** rename the *current*
branch in place to bring it into Git Flow prefix compliance ("follow the
project's flow"), while the ban on **creating** and **switching** branches (and
creating an `aoe` session) stays fully intact. The edit is confined to the
"Branch ownership and naming" section of `dot_agents/readonly_AGENTS.md`, the
single source of truth that renders into every agent's instruction file
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`,
`~/.pi/agent/AGENTS.md`, `~/.agents/AGENTS.md`).

**Product Contract preservation:** n/a — solo bootstrap plan, no upstream
requirements doc.

---

## Problem Frame

Today the core forbids renaming outright. Two clauses block it:

- **Creation ownership clause** (`dot_agents/readonly_AGENTS.md:71`) lumps
  `git branch -m` into the same `MUST NOT` list as `git checkout -b` /
  `git switch -c` / `git branch`.
- **Naming clause** (`dot_agents/readonly_AGENTS.md:73`) ends: "A noncompliant
  current branch → **STOP** and ask the user or `aoe` owner to resolve it;
  **MUST NOT** rename it automatically."

The consequence: when the current branch lacks a Git Flow prefix (e.g. a bare
`khitans` or `add-widget`), the agent must halt and hand the trivial fix back to
a human instead of simply renaming `add-widget` → `feature/add-widget`. The user
wants that rename permitted — it *follows* the established flow rather than
inventing new branch topology — without reopening the door to branch **creation**.

### Scope boundary — what stays blocked

- Creating a branch (`git checkout -b`, `git switch -c`, `git branch <new>`).
- Switching branches.
- Creating an `aoe` session.
- Creating a sibling branch (the "one task = one branch" rule, line 74).
- Renaming a branch to match its worktree directory (existing layout rule,
  line 42).

The only thing newly permitted is an **in-place rename of the current branch to
add a Git Flow prefix**, under safety conditions (below).

---

## Requirements

- **R1** — The core MUST allow renaming the current branch in place
  (`git branch -m`) for the sole purpose of adding a Git Flow prefix that brings
  it into compliance.
- **R2** — The core MUST continue to forbid creating and switching branches and
  creating an `aoe` session, with no weakening of those prohibitions.
- **R3** — The rename allowance MUST be bounded by safety conditions so it never
  becomes an outward-facing or destructive operation:
  - only an **unpushed** branch (no upstream / absent from the remote) may be
    renamed — a pushed branch keeps the STOP-and-ask escape hatch, because
    renaming it would diverge from the remote / an open PR;
  - when the correct prefix is **genuinely ambiguous**, keep STOP-and-ask rather
    than guessing;
  - the default branch (`main`/`master`) is untouched (already prefix-exempt).
- **R4** — The two edited clauses MUST stay internally consistent (the creation
  clause and the naming clause must agree that `git branch -m`-for-prefix is the
  one carve-out) and consistent with the existing worktree-dir rule (line 42).
- **R5** — The edit MUST be a pure content change to `dot_agents/readonly_AGENTS.md`
  and MUST NOT alter the source-attribute prefix (stays `readonly_`), so the
  render targets and their modes are unchanged.

---

## Key Technical Decisions

- **KTD1 — Edit the SSOT only.** All change goes into
  `dot_agents/readonly_AGENTS.md`. The four wrapper templates inline it verbatim
  via `{{ include "dot_agents/readonly_AGENTS.md" }}`, so they need no edits and
  MUST NOT be touched (per the repo's "update common instructions in
  `dot_agents/readonly_AGENTS.md` ONLY" rule).

- **KTD2 — Two-clause edit, not a new section.** Modify the creation-ownership
  bullet (line 71) to drop `git branch -m` from the forbidden list and name the
  carve-out, and rewrite the naming bullet (line 73) to permit the prefix-adding
  rename under the safety conditions. No new heading — the relaxation lives where
  the rule already lives, keeping the guardrail scannable.

- **KTD3 — Rename gated on "unpushed".** Bound the allowance to a branch with no
  upstream / not yet on the remote. This keeps the rename a local, reversible,
  non-outward-facing action and sidesteps remote-rename / PR-retargeting
  complications — consistent with the global guardrail against unrequested
  outward-facing operations. A pushed branch retains STOP-and-ask.

- **KTD4 — Keep an ambiguity escape hatch.** When the branch's purpose does not
  map cleanly to a prefix, the agent still STOPs and asks rather than guessing.
  This preserves the guardrail's intent (don't fabricate) while removing friction
  for the common, unambiguous case the user actually hit.

- **KTD5 — Repo-root `AGENTS.md` override: flag, do not silently edit.** This
  repo's own `AGENTS.md` "Commits and branch ownership" section
  (`AGENTS.md:1397-1398`) independently states agents "MUST NOT create, rename,
  or switch branches", and by the core's own precedence line ("Project-level
  `AGENTS.md` overrides any rule here on conflict") that override would re-block
  the new rename *inside this repo*. See Open Questions — this is surfaced to the
  user for an explicit decision rather than folded in silently, since the request
  named only `dot_agents/readonly_AGENTS.md`.

---

## Implementation Units

### U1. Relax the creation-ownership clause to carve out in-place rename

**Goal:** Stop the creation-ownership bullet from forbidding `git branch -m`,
while keeping create/switch/aoe-session prohibitions intact.

**Requirements:** R1, R2, R4, R5.

**Dependencies:** none.

**Files:**
- `dot_agents/readonly_AGENTS.md` (modify the bullet currently at line 71).

**Approach:** Remove `git branch -m` from the parenthetical forbidden-command
list and change "create, rename, or switch branches" to "create or switch
branches". Append one sentence stating that renaming the *current* branch in
place with `git branch -m` is the single permitted exception, allowed **only** to
reach Git Flow compliance under the conditions in the naming bullet below, and
never a licence to create, switch, or fork a branch. Preserve the existing
"overrides generic commit/worktree skills" sentence and the RFC-2119 bolding
convention.

**Patterns to follow:** the surrounding bullets' RFC-2119 style (`**MUST NOT**`,
`**MAY**`), inline `code` for git commands, em-dash asides.

**Test scenarios:** `Test expectation: none — documentation content change, no
executable behavior.` Verification is by render + read-through (U3).

### U2. Rewrite the naming clause to permit the prefix-adding rename

**Goal:** Replace the flat "STOP … MUST NOT rename it automatically" ending with
a conditional allowance to rename the current branch in place to add the matching
Git Flow prefix, retaining STOP-and-ask for the pushed and ambiguous cases.

**Requirements:** R1, R2, R3, R4, R5.

**Dependencies:** U1 (the two bullets must land together and agree).

**Files:**
- `dot_agents/readonly_AGENTS.md` (modify the bullet currently at line 73).

**Approach:** Keep the prefix list and the "before its first commit, run
`git branch --show-current`" check unchanged. Replace the final sentence with:
a **noncompliant, not-yet-pushed** current branch **MAY** be renamed in place
with `git branch -m` to add the prefix that matches the work, preserving the rest
of the slug (worked example: `add-widget` → `feature/add-widget`); if the branch
is already pushed **or** the correct prefix is genuinely ambiguous, **STOP** and
ask the user or `aoe` owner instead, and never rename a branch to match its
worktree directory (cross-reference the layout rule). Confirm the wording does
not contradict line 42 or line 74.

**Patterns to follow:** existing branch-naming bullet phrasing and prefix list;
line 42's worktree-dir rule for the cross-reference wording.

**Test scenarios:** `Test expectation: none — documentation content change.`
Consistency is checked by read-through in U3 (no create/switch/sibling weakening;
pushed + ambiguity escape hatches present; example correct).

### U3. Verify render parity and content integrity

**Goal:** Prove the edited source still renders cleanly for every consumer and
that the change is confined to the intended clauses.

**Requirements:** R4, R5.

**Dependencies:** U1, U2.

**Files:**
- `dot_agents/readonly_AGENTS.md` (read-only verification).
- wrapper targets are NOT edited — only confirmed to still inline the source.

**Approach (verification, not a code change):**
- Render one wrapper through the stub-`op` + throwaway-destination recipe from
  the repo AGENTS.md and confirm the new text appears, e.g.
  `chezmoi execute-template < dot_claude/readonly_CLAUDE.md.tmpl` under the
  isolated recipe, exit 0.
- `git diff --stat` shows exactly one changed file
  (`dot_agents/readonly_AGENTS.md`) with only the two clauses touched.
- Read-through the final section to confirm: create/switch/aoe-session and
  sibling-branch prohibitions unweakened; rename allowance present and bounded;
  no contradiction with lines 42 / 74.

**Execution note:** This is a docs/config change — prefer a render smoke check
over unit tests. No `.chezmoiscripts/` script consumes this file, so there is no
`run_onchange_` side effect to trace; the change only re-renders the five managed
instruction targets.

**Test scenarios:** `Test expectation: none — verification is the render smoke
check and diff/read-through above.`

---

## Verification Contract

- Rendering `dot_agents/readonly_AGENTS.md` (directly or via any wrapper) through
  the stub-`op` recipe exits 0 and contains the relaxed rename wording.
- `git diff` touches exactly one file with only the two targeted bullets changed;
  the `readonly_` source attribute and the five render targets are unchanged.
- Read-through confirms R1–R4 hold: rename-for-prefix permitted; create/switch/
  aoe-session/sibling still forbidden; pushed-branch and ambiguity STOP-and-ask
  retained; no conflict with the worktree-dir rule.

## Definition of Done

- U1 + U2 landed in `dot_agents/readonly_AGENTS.md`, mutually consistent.
- U3 render smoke check and diff/read-through pass.
- The repo-root `AGENTS.md` override (KTD5 / Open Question) is surfaced to the
  user with a recommendation, so its resolution is an explicit decision, not a
  silent omission.

---

## Scope Boundaries

**In scope:** the two-clause edit to `dot_agents/readonly_AGENTS.md` and its
render verification.

### Deferred to Follow-Up Work

- Aligning the repo-root `AGENTS.md` "Commits and branch ownership" section
  (lines 1397–1398) — deferred *pending the user's answer* to the Open Question
  below, not silently dropped. If the user wants the rename allowance to also
  take effect **inside this repo**, that section (which currently overrides the
  core) must be updated in the same change; the request as written named only the
  core file.

**Out of scope:** any change to the user's private global `~/.claude/CLAUDE.md`
(not managed by this repo), and any change to branch *creation*/switch policy.

---

## Open Questions

- **OQ1 (needs user decision) — repo-root override.** The chezmoi repo's own
  `AGENTS.md` still says agents "MUST NOT create, rename, or switch branches" and,
  by the core's precedence rule, overrides the relaxed core *within this repo*.
  Options: (a) update that section too so the rename allowance is effective here
  as well as everywhere else (recommended for consistency — otherwise the change
  is inert in the very repo the user is working in); (b) leave it as a deliberate
  stricter local policy for the chezmoi repo. Recommended: **(a)**. Because the
  request explicitly scoped to `dot_agents/readonly_AGENTS.md`, this is surfaced
  rather than assumed.

---

## Sources & Research

- `dot_agents/readonly_AGENTS.md` — "Branch ownership and naming" section
  (lines 69–74) and "Project layout" line 42 (worktree-dir rule).
- Repo `AGENTS.md` — "Single source of truth" (edit the core only; wrappers are
  bare `include`s) and "Commits and branch ownership" (lines 1397–1398, the
  overriding project rule).
- Repo `AGENTS.md` — "Verify edits" stub-`op` + throwaway-destination recipe
  (render verification for U3).
- No external research: this is an in-repo documentation/policy edit with strong
  local convention to follow.
