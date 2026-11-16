---
title: Issue Closing from PRs and MRs - Plan
type: feat
date: 2026-11-16
topic: issue-closing-pr-mr
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Issue Closing from PRs and MRs - Plan

## Goal Capsule

- **Objective:** Issues that agent-authored PRs and MRs resolve close when those PRs and MRs merge, partly resolved issues stay open and visibly linked to the work, and a T3 Code thread that ships one issue across several PRs or MRs stays active until the last one merges.
- **Means:** Two new instruction sections in the shared harness template (KTD1).
- **Product authority:** The repository owner, through this Product Contract; the Product Contract outranks the Planning Contract, which outranks the units.
- **Execution profile:** One PR, three units, no runtime or host change.
- **Stop conditions:** Stop if rendering the template for any harness fails, or if a T3-only sentence appears in a baseline render.
- **Who finishes:** The executing agent implements, verifies, and opens the PR; the owner merges.
- **Open blockers:** None.

---

## Product Contract

### Summary

Every managed harness gets a common rule for linking issues when it creates a PR or MR. The agent writes `Closes #N` for issues the change fully resolves and `Related to #N` for issues it only partly resolves. Agents plan each issue-driven task so that the issue closes from an MR, and split the work into several PRs or MRs up front when one cannot finish it. In T3 Code, a thread whose plan has several PRs or MRs is pinned so that auto-settle does not settle it between merges.

### Problem Frame

Agents open PRs and MRs without referencing the issues behind them. After a merge the owner has to find and close those issues by hand, and nothing records which change resolved which issue. Work scoped to a request smaller than its issue can also leave the issue half done without saying what remains.

In T3 Code, the owner's settings enable `sidebarAutoSettleOnMerge` (`home/h82/t3code.nix:64`). When work ships as a sequence of PRs, the thread settles as soon as every linked PR has merged, which happens in the gap after one PR merges and before the agent opens the next. The thread then drops out of the active sidebar while the work is unfinished.

---

### Key Decisions

- **Link named issues first, then search open issues when none is named.** Named issues alone would miss most links, and creating issues adds outward-facing writes. Governs R1, R2, R3. (session-settled: user-directed — chosen over linking only named issues and over creating an issue when none exists: search finds the links that naming misses without creating new issues on the forge)
- **An assigned issue defines the scope: widen the work to close it, and split it into several PRs or MRs from the plan stage when one cannot.** Governs R8, R9, R10. (session-settled: user-directed — chosen over filing follow-up issues for the remainder and over mention-only at the requested scope: the MR, not the owner, should close the issue)
- **Pin the thread to keep multi-PR work out of T3 auto-settle.** T3 Code 0.1.9 stores a per-thread auto-settle opt-out (`thread.auto-settle.set`), but only the sidebar UI can set it; no MCP tool exposes it. A pinned thread is never an auto-settle candidate, and agents can pin through `t3_thread_organize`. Governs R12, R13. (session-settled: user-directed — chosen over asking the user to turn off auto-settle in the thread menu and over linking PRs early and unsettling afterwards: the agent can do it alone and the thread never settles in between)
- **GitHub and GitLab share one rule.** `Closes #N` is a default closing keyword on both forges. Governs R7.

---

### Requirements

**Finding the issues**

- R1. When creating a PR or MR, the agent links every issue that the user, the branch, the commits, or the governing plan names for the work.
- R2. When no issue is named, the agent searches the repository's open issues and links those that the change resolves or advances.
- R3. The agent does not create an issue in order to have one to link; issue search is read-only.

**Closing and mentioning**

- R4. Each issue the PR or MR fully resolves appears in its description as `Closes #N`, one issue per line, using the full `group/project#N` or `owner/repo#N` reference for an issue in another project.
- R5. Each issue the PR or MR only partly resolves appears as `Related to #N` without a closing keyword, and the description states what remains.
- R6. Closing keywords appear only in PR and MR descriptions, never in commit messages.
- R7. The same rule applies to GitHub PRs and GitLab MRs.

**Work posture**

- R8. Work that starts from an issue treats the whole issue as the request, and the template states that this is the intended scope under the common "Scope and verification" rule rather than an exception to it.
- R9. When one PR or MR cannot close an assigned issue, the plan splits the issue into several PRs or MRs from the start; every PR or MR before the last one mentions the issue per R5, and the one that completes it closes it per R4.
- R10. An assigned issue stays open after its planned PRs or MRs merge only when the user narrowed the scope, and the last PR or MR then mentions it per R5.
- R11. An issue found only by search (R2) never widens the scope; it is closed only when the change fully resolves it, and mentioned otherwise.

**T3 Code auto-settle**

- R12. In a T3 Code thread whose plan has more than one PR or MR, the agent pins the thread with `t3_thread_organize` when it creates the first PR or MR.
- R13. The agent unpins the thread after the last planned PR or MR merges, only if the agent pinned it; while planned PRs or MRs remain at handback, the thread stays pinned and the agent's report says so.

**Placement**

- R14. R1 through R11 live in the common branch of the shared template, reaching all five managed harnesses in both CLI and T3 sessions; R12 and R13 live in the T3-only branch.

---

### Acceptance Examples

- AE1. **Covers R2, R4, R11.** **Given** no issue is named and the open issues include one bug this change fixes and one broader feature request it touches, **when** the agent opens the PR, **then** the description has `Closes #` for the bug and `Related to #` for the feature request, and the work did not grow to finish the feature request.
- AE2. **Covers R8, R9, R12, R13.** **Given** the user asks the agent in T3 Code to resolve issue #40 and the plan needs three MRs, **when** the agent opens the first MR, **then** it pins the thread; MR 1 and MR 2 say `Related to #40`, MR 3 says `Closes #40`, and the agent unpins the thread after MR 3 merges.
- AE3. **Covers R13.** **Given** the user had already pinned the thread before the work started, **when** the last planned MR merges, **then** the thread stays pinned.
- AE4. **Covers R10.** **Given** the user says to fix only the first of the three problems in issue #12, **when** the agent opens the single PR, **then** the description says `Related to #12` and lists the two remaining problems.
- AE5. **Covers R12.** **Given** a plan with exactly one PR, **when** the agent opens it in T3 Code, **then** the thread is not pinned.

---

### Scope Boundaries

- Creating issues, including follow-up issues for the unfinished parts of a partly resolved issue.
- Turning off auto-settle globally by changing `sidebarAutoSettleOnMerge` in `home/h82/t3code.nix`.
- Switching from pinning to T3 Code's per-thread auto-settle opt-out once T3 Code exposes it as an MCP tool.
- Closing keywords in commit messages.
- Closing, labeling, or commenting on issues directly through `gh` or `glab` instead of through the merge.

---

### Dependencies / Assumptions

- Both forges act on closing keywords only when the PR or MR merges into the project's default branch, and GitLab honors the project's closing pattern setting.
- T3 Code 0.1.9 auto-settle on merge waits while any linked PR is open and never settles a pinned thread (`resolveAutoSettlementAt` and `isAutoSettlementCandidate` in the bundled server).
- Changing the template follows the repository's existing rules: update the receipt hashes in `tests/agent-instructions.py` and keep `docs/agent-routing.md` aligned, mirroring T3 sections verbatim.

---

### Outstanding Questions

**Deferred to Planning**

- How R4 and R9 behave for stacked PRs or MRs whose base is not the default branch, such as `gh-stack` layers, where a closing keyword does not fire at merge.
- How the agent judges, during the R2 search, that a change "resolves or advances" an issue, and how far that search goes.

---

### Sources / Research

- GitLab default closing pattern: <https://docs.gitlab.com/user/project/issues/managing_issues/#default-closing-pattern>
- GitHub closing keywords: <https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue>
- `home/h82/agents/instructions/instructions.md.tmpl`: the common "Scope and verification" section and the T3-only "T3 PR and MR babysitting" section that the new sections sit beside.
- `home/h82/t3code.nix:64`: `sidebarAutoSettleOnMerge = true`, `sidebarAutoSettleAfterDays = 3`, `sidebarAutoSettleKeepPullRequests = true`.
- T3 Code 0.1.9 MCP tool list: `t3_thread_organize` offers pin, unpin, snooze, settle, unsettle, archive, and mark unread; `t3_environment_preferences_update` and `t3_project_update` have no auto-settle field.

---

## Planning Contract

Product Contract preservation: Product Contract unchanged.

### Key Technical Decisions

- KTD1. **One common section and one T3-only section in `home/h82/agents/instructions/instructions.md.tmpl`.** The common section sits after "Scope and verification" so its scope sentence (R8) reads right after the rule it qualifies; the T3 section sits after "T3 PR and MR babysitting", next to the other PR lifecycle rule. Implements R14.
- KTD2. **The T3 section names `t3_thread_organize` with `action: pin` and `action: unpin` and says why pinning is used.** The reason sentence keeps a future reader from swapping in a settle or snooze action that does not block auto-settle. Implements R12 and R13 under the Product Contract's pin Key Decision.
- KTD3. **No stacked-PR rule.** R4 already puts `Closes` on the PR or MR that completes the issue wherever it sits in a stack; adding a retarget or post-merge check rule would conflict with the common "Scope and verification" ban on added verification rules. Accepted risk below.
- KTD4. **The existing full-body receipt hashes are the only test change.** `tests/agent-instructions.py` hashes every rendered body and rejects negated, repeated, deleted, and foreign text, so a new sentence check would duplicate it.

### Assumptions

- The Antigravity rule-file split keeps each file under the 24000-byte limit `tests/agent-instructions.py` enforces after the common body grows.

### Risks

- T3 Code 0.1.9 exposes no thread pin state to agents (`t3_thread_list` and `t3_thread_read` return none), so R13 relies on the agent remembering that it pinned the thread. A thread the user pinned before the work cannot be told apart, so AE3 holds only when the user says the thread was already pinned.
- An issue completed by a stacked PR whose base is not the default branch may stay open after the stack lands (KTD3). The owner sees it in the issue list; the cost is a manual close.

---

## Implementation Units

### U1. Common issue-linking section

- **Goal:** Every managed harness links and closes issues from PR and MR descriptions.
- **Requirements:** R1–R11, R14 (part); AE1, AE4.
- **Dependencies:** None.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `docs/agent-routing.md`.
- **Approach:**
  1. Add a heading such as `# Issues in pull and merge requests` in the common (`else`) branch after "Scope and verification".
  2. Write one short paragraph or bullet per rule group: finding issues (R1–R3), closing and mentioning (R4–R7), work posture (R8–R11).
  3. Write the R8 sentence so it reads as the intended scope under "Scope and verification", not an exception.
  4. Keep wording harness-neutral: no T3 tool names, no `.claude` branch.
  5. Add issue linking to the opening sentence of `docs/agent-routing.md` that lists the common rules.
- **Patterns to follow:** The terse imperative style of the "Scope and verification" and "Language" sections.
- **Test scenarios:** Covered by U3's receipt update; the render check fails if the section leaks into or out of the wrong branch.
- **Verification:** The section renders in the darwin, nixos, and Claude baseline bodies and not in the T3 body.

### U2. T3 auto-settle pin section

- **Goal:** Multi-PR work in T3 Code keeps its thread active until the last PR merges.
- **Requirements:** R12, R13, R14 (part); AE2, AE3, AE5.
- **Dependencies:** None.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `docs/agent-routing.md`.
- **Approach:**
  1. Add `# T3 multi-PR threads` (or similar) in the `.t3` branch after "T3 PR and MR babysitting" (KTD1, KTD2).
  2. Mirror the section verbatim under a matching `##` heading in `docs/agent-routing.md`, as the existing T3 sections are mirrored.
- **Patterns to follow:** The "T3 PR and MR babysitting" section and its mirror in `docs/agent-routing.md`.
- **Test scenarios:** Covered by U3's T3 receipt.
- **Verification:** The section appears in the T3 render only.

### U3. Receipt hashes

- **Goal:** The instruction check proves the new rendered bodies.
- **Requirements:** R14.
- **Dependencies:** U1, U2.
- **Files:** `tests/agent-instructions.py`.
- **Approach:** Recompute the five `EXPECTED` hashes (`darwin`, `darwin-claude`, `nixos`, `nixos-claude`, `t3`) from the real renderer output after U1 and U2, and replace them (KTD4).
- **Test scenarios:**
  - Covers AE1–AE5 indirectly: the check passes with the new hashes and fails if either section is removed or moved to the other branch.
- **Verification:** `agent-instructions` builds.

---

## Verification Contract

| Gate | Command | Applies to |
| --- | --- | --- |
| Instruction render and receipts | `nix build --no-link .#checks.x86_64-linux.agent-instructions` | U1–U3 |
| Formatting | `nix fmt -- --ci` | all |
| Markdown | `markdownlint-cli2` on changed Markdown | U2, plan |
| Whitespace | `git diff --check` | all |

CI's `light-*` shards rerun these; the change touches no host closure.

## Definition of Done

- U1–U3 are in one commit set on one PR, and every gate above passes locally.
- The T3 render contains the pin section, and no baseline render contains it.
- `docs/agent-routing.md` mirrors the new T3 section verbatim.
- No abandoned drafts or stray edits remain in the diff.
