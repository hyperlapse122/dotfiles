---
title: Close Review-Finding Out-of-Scope Deferral Loophole - Plan
type: fix
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Close Review-Finding Out-of-Scope Deferral Loophole - Plan

## Goal Capsule

- **Objective:** An agent run through `home/.chezmoitemplates/agents-instructions.tmpl` can no longer defer an actionable code-review finding merely because its fix sits outside the branch's changed files; the only two surviving deferral reasons are a product/design decision the run cannot make, or a confirmed blocker, and every other actionable finding lands in the same MR/PR as its own commit under its own heading.
- **Means:** Edit the deferral-rule and Claude harness-tuning paragraphs in `home/.chezmoitemplates/agents-instructions.tmpl`, and keep `.ci/test-agent-instructions.sh` and its fixture in sync so the CI gate that pins this text passes (KTD1, KTD2).
- **Authority hierarchy:** GitHub issue #561 (`hyperlapse122/dotfiles`) states the requirement; this plan and `.ci/test-agent-instructions.sh` are authoritative for exact wording.
- **Stop conditions:** stop if the retired phrase or its defining sentences appear anywhere the CI gate does not already cover (none found by search); stop if `bash .ci/test-agent-instructions.sh` fails after the edit.
- **Execution profile:** single-session text edit, no runtime component, no rollout.
- **Finishes and ships:** this run — implements, reviews, commits, opens and merges the PR.

## Product Contract

### Summary

Issue #561 removes "the fix falls outside the scope of the branch under review" as a valid reason to defer an actionable code-review finding, because in practice it becomes the reviewer's default excuse to file a tracker issue instead of fixing the finding while context is loaded. The remaining two reasons (a product/design decision, or a confirmed blocker) keep their existing tracker-filing and committed-record fallback. The paragraph gains one sentence stating that an out-of-branch fix instead lands in the same MR/PR under review, as its own commit, under its own heading in the MR/PR description — never a follow-up MR/PR. The Claude harness-tuning paragraph's "report other findings as follow-ups" line, which now contradicts that rule for code-review findings, gets an explicit exception.

### Problem Frame

`home/.chezmoitemplates/agents-instructions.tmpl` composes into every managed harness's user-scoped instruction file. Its finding-deferral rule currently treats "fix touches files outside the branch" as sufficient grounds to defer to a tracker issue, which undermines the rule's own stated goal (every actionable finding fixed in the run that found it, "in the same run that found it").

### Requirements

- R1. `home/.chezmoitemplates/agents-instructions.tmpl`'s finding-deferral sentence lists only two deferral reasons — a product/design decision the run cannot make, or a confirmed blocker — and no longer mentions branch scope.
- R2. The two sentences that define the "in scope by default" / "out-of-scope deferral" test are removed from that paragraph.
- R3. The same paragraph states that an out-of-branch fix lands in the same MR/PR under review, as its own commit, listed under its own heading in the MR/PR description, and never in a follow-up MR/PR.
- R4. The Claude harness-tuning paragraph's "report other findings as follow-ups" sentence carries an explicit exception for code-review findings, which are fixed in-run instead of reported as a follow-up.
- R5. `.ci/test-agent-instructions.sh`'s NEEDLES list and the `harness-runs-claude.txt` fixture stay synchronized with the edited template text, and `bash .ci/test-agent-instructions.sh` passes.

### Scope Boundaries

- In scope: the finding-deferral paragraph and the Claude harness-tuning paragraph in `home/.chezmoitemplates/agents-instructions.tmpl`, plus the CI needle list and fixture that pin them.
- Out of scope: any other content in that same template file — a sibling issue (#562) edits it elsewhere in parallel in a different worktree; touch only the two named paragraphs. Do not run `chezmoi apply` against the live home directory to verify rendering; CI's sandboxed `execute-template` render (`.ci/test-agent-instructions.sh`) is the verification path instead, per the template's own instruction to edit only the source.

### Risks & Dependencies

- A sibling worker is editing the same template file (issue #562) concurrently in a different worktree. Mitigation: this plan's diff is limited to two specific paragraphs, minimizing overlap; resolve any merge conflict at PR-merge time by keeping both sides' paragraph edits (they touch different text).

## Planning Contract

- KTD1. Keep "A deferred finding is then filed as an issue in the project's tracker" verbatim after R1/R2's edit, rather than rewriting it to spell out "for the two remaining reasons." Rejected alternative: rewording that sentence — rejected because the paragraph already lists only two reasons at that point, so restating the count adds no information and the plan-sections economy rule disfavors restating what the surrounding text already establishes.
- KTD2. Sync `.ci/test-agent-instructions.sh`'s NEEDLES heredoc by deleting the two needles asserting the retired sentences and adding one needle for the new landing-location sentence, rather than leaving retired needles in place (fails CI, since the asserted text no longer exists) or leaving the new rule unasserted (silently weakens the gate's coverage of this paragraph relative to the density of needle coverage the rest of the file already has).

### Assumptions

- Headless run, no human present: the branch is renamed to a `docs/`-prefixed Git-Flow slug before the first push, since the change is confined to instruction/template prose and CI test configuration, not application code.

## Implementation Units

### U1. Rewrite the deferral-rule and harness-tuning paragraphs

**Goal:** Satisfy R1-R4 in `home/.chezmoitemplates/agents-instructions.tmpl`.
**Requirements:** R1, R2, R3, R4
**Dependencies:** none
**Files:** `home/.chezmoitemplates/agents-instructions.tmpl`
**Approach:**
- In the Claude harness-tuning block (between `{{ if eq .harness "claude" -}}` and `{{- else if eq .harness "codex" -}}`), append an exception clause to the paragraph's closing sentence so it reads: "...report other findings as follow-ups, except a code-review finding: fix it in the run that found it instead of reporting it as a follow-up." (R4)
- In the "Branches, commits, issues, blockers" section's finding-deferral paragraph, replace the three-reason "Defer a finding only when..." sentence with the two-reason version (R1); delete the "A finding whose fix touches only files the branch already changes is in scope by default..." and "Only a fix that requires touching files outside the branch's changes qualifies for the out-of-scope deferral." sentences (R2); insert one sentence in their place stating the landing location per KTD1 (R3); leave the following "A deferred finding is then filed as an issue in the project's tracker." sentence and the rest of the paragraph untouched.
**Patterns to follow:** the file's existing register — very long compound MUST/never sentences; match that style rather than shortening unrelated text nearby.
**Test scenarios:**
- Test expectation: none -- prose/template edit with no executable branching; correctness is verified by U2's CI gate and needle assertions, not unit tests.
**Verification:** the two target paragraphs read as specified in R1-R4 when the file is read back; `grep -rn "falls outside the scope of the branch\|in scope by default\|out-of-scope deferral" home/.chezmoitemplates/agents-instructions.tmpl` returns no matches.

### U2. Sync the CI gate fixture and needles

**Goal:** Satisfy R5.
**Requirements:** R5
**Dependencies:** U1
**Files:** `.ci/fixtures/agent-instructions/harness-runs-claude.txt`, `.ci/test-agent-instructions.sh`
**Approach:**
- Update `harness-runs-claude.txt` to the exact new `This harness runs Anthropic Claude models...` line (byte-for-byte, single line, trailing newline preserved) so the fixture diff in `.ci/test-agent-instructions.sh` (`diff -q "$runs_fixture" "$runs_line"`) matches the rendered template.
- In the NEEDLES heredoc (`.ci/test-agent-instructions.sh`), remove the two needle lines quoting the retired "in scope by default" / "out-of-scope deferral" sentences and add one needle line quoting the new landing-location sentence from U1.
**Patterns to follow:** existing NEEDLES heredoc entries are literal substrings of the template's paragraphs (`.ci/test-agent-instructions.sh:377-488`).
**Test scenarios:**
- Test expectation: none -- CI fixture/config sync, not application behavior; verified directly by running the gate script itself.
**Verification:** `bash .ci/test-agent-instructions.sh` exits 0 and prints `agent instruction gates passed`.

## Verification Contract

- `bash .ci/test-agent-instructions.sh` — covers U1, U2. Byte-exact fixture diff plus the full needle/banned-phrase gate over the rendered instruction payloads for all three harnesses; must exit 0.
- `shellcheck .ci/test-agent-instructions.sh` — covers U2. No new warnings beyond the pre-existing SC1091 info note on the `source` line.

## Definition of Done

- R1-R5 all hold in the working tree.
- `bash .ci/test-agent-instructions.sh` passes.
- The worktree diff touches only `home/.chezmoitemplates/agents-instructions.tmpl`, `.ci/fixtures/agent-instructions/harness-runs-claude.txt`, and `.ci/test-agent-instructions.sh` (plus this plan file).
- Branch renamed to a work-descriptive Git-Flow slug before the first push.
- PR opened against `main` with `Closes #561` (every issue acceptance criterion is met) and the Claude Code attribution line; CI green; PR merged.
