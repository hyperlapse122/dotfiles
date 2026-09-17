---
title: Skill Preamble Re-arm Rule - Plan
type: chore
date: 2026-09-17
topic: skill-preamble-rearm-rule
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Skill Preamble Re-arm Rule - Plan

## Goal Capsule

- **Objective:** A long-running command that an agent re-issues from a skill's written recipe carries the same safety and capability preflight as the first issue, on every harness, so a re-armed watcher never depends on the first call's leftovers or on a host accident.
- **Means:** One shared paragraph in `.chezmoitemplates/agents-instructions.tmpl`, pinned by needles in `.ci/test-agent-instructions.sh` (KTD1, KTD3).
- **Product authority:** [hyperlapse122/dotfiles#532](https://github.com/hyperlapse122/dotfiles/issues/532). The PR that lands this plan fully resolves the issue and carries `Closes #532`.
- **Stop conditions:** Any fixture under `.ci/fixtures/agent-instructions/` needs a change to make the gate pass. That means the paragraph landed inside a fixture-bound region, and the placement is wrong, not the fixture.
- **Execution profile:** Lightweight. Two units, one change set, no new files outside `docs/plans/`.
- **Who finishes and ships:** The `lfg` run that owns this plan implements, reviews, commits, opens the PR, watches CI, and merges.

## Product Contract

### Summary

Add one shared paragraph to the instruction core that binds every harness to re-issue a skill's documented long-running command as written, preamble included, on the first call and on every re-arm. Pin the paragraph's load-bearing sentences with `NEEDLES` entries so a render that drops it fails CI. State in the resolution that the rule is instruction-only, because the divergence lives in agent tool calls the repository never sees.

### Problem Frame

A `ce-babysit-pr` session on PR #531 armed the skill's background watcher twice. The first arm was transcribed from the skill's `references/tick.md` and carried the scratch-root symlink, ownership, and writability tests, the `TMPDIR` fallback, the `chmod 700` on both directories, and the `PY` interpreter probe. The hand-written re-arm a few tool calls later kept only the path assignments and hardcoded `python3`. Nothing failed, because the first arm had already created the directories with the right mode and the host has `python3` on `PATH`. On a host with only `python`, or with a primed `/tmp`, the re-arm is where the watcher breaks, and it breaks in the background as a watcher that never wakes.

The instruction core already fixes how a coordinator wait runs, in the Claude `This harness is` paragraph, and what form a dispatched-worker wait takes, in `## Waiting on dispatched workers`. Neither rule reaches a re-issued skill recipe, and the skill printing the full recipe at both call sites was not enough on its own.

### Requirements

**Rule text**

- R1. The shared body of `.chezmoitemplates/agents-instructions.tmpl` carries a paragraph that requires an agent to issue a skill's literal long-running or backgrounded command as the skill writes it, preamble included, on the first call and on every re-arm.
- R2. The paragraph forbids dropping, shortening, or replacing with a hardcoded value any preflight step in that recipe because an earlier call in the same session already satisfied it.
- R3. The paragraph states that a re-issued command which omits a recipe preflight step because an earlier call's side effects remain is a new command, not the documented one. State and run values that the recipe itself tells a re-arm to reuse stay allowed.
- R4. The paragraph names the substitution points a skill's recipe legitimately leaves to the run, such as a path or an identifier, as the only places the agent changes the text. A prohibition elsewhere in the file on a token in that command, such as the executable-selection rule for bare `orca`, still governs that token and never licenses dropping a preflight step.
- R5. The paragraph renders identically for `claude`, `codex`, and `omp` and sits outside the `This harness is` block and outside every fixture-bound region.

**Gate**

- R6. `.ci/test-agent-instructions.sh` fails when any render of the shared body loses the paragraph's MUST sentence, its MUST NOT sentence, its new-command sentence, or its substitution sentence.
- R7. Every file under `.ci/fixtures/agent-instructions/` is byte-identical before and after the change.

**Record**

- R8. The PR description states that the rule is instruction-only and that no CI gate can observe the agent tool calls where the divergence occurs.

### Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given a skill recipe whose first arm ran the scratch-root tests and the interpreter probe, when the agent re-arms the same watcher later in the session, then the re-arm carries the same tests and probe and does not substitute `python3` for the probed interpreter.
- AE2. **Covers R4.** Given a recipe with `SKILL_DIR`, a PR number, and a state-directory name left to the run, when the agent issues it, then those values are filled in and every other token stays as the skill wrote it.
- AE3. **Covers R5, R6.** Given the paragraph removed from the template, when `.ci/test-agent-instructions.sh` runs, then it fails on the first lost needle, naming that needle and the harness, and no fixture comparison changes state. The shared-body needle loop uses the exiting `fail`, so later needles are not reported in the same run.

### Scope Boundaries

- The `This harness is` paragraphs, the `This harness runs` lines, the `lfg` and workflow-required autonomy paragraphs, and `## Waiting on dispatched workers` are unchanged.
- No fixture is regenerated (R7).
- No hook, wrapper, or tool-call inspector is added. The repository cannot see agent tool calls, so no mechanical gate on the behavior exists (KTD2).
- The `ce-babysit-pr` skill and its `references/tick.md` are outside this repository and are not modified.
- `AGENTS.md` is unchanged. Its description of the fixture-backed paragraphs and of the review obligation for unbounded shared-body sections stays true after this change.

### Sources / Research

- `.chezmoitemplates/agents-instructions.tmpl:47-61` — the `## File edits and native tools` section: the shared native-tools paragraph, the harness-conditional block, and the shared "A script MAY" paragraph the new rule follows.
- `.chezmoitemplates/agents-instructions.tmpl:63` — the `## Waiting on dispatched workers` heading. The section is compared whole against `.ci/fixtures/agent-instructions/waiting-on-dispatched-workers.txt`, so text placed under it forces a fixture change.
- `.ci/test-agent-instructions.sh:56-60` — the header note that every shared-body section outside the fixture-bound ones is unbounded, and that a needle is the pin for a rule there.
- `.ci/test-agent-instructions.sh:357-374` — the shared-body needle loop, which greps each needle against the harness-stripped render of all three harnesses.
- `.ci/test-agent-instructions.sh:374-465` — the `NEEDLES` heredoc where the new entries go.
- `.ci/test-agent-instructions.sh:323-327` — the peer diff that requires the shared body to match across harnesses.
- `AGENTS.md:77` — the rule that a reworded fixture-backed paragraph updates its fixture in the same commit, and that a contradicting sentence elsewhere in the shared body is a review obligation.
- Issue #532 — the first-arm and re-arm transcripts and the proposed rule text.

## Planning Contract

### Key Technical Decisions

- KTD1. **The rule is a new shared paragraph in `## File edits and native tools`, placed after the "A script MAY" paragraph and before `## Waiting on dispatched workers`.** The defect is not Orca-specific: a `ce-babysit-pr` watcher is a skill recipe in an ordinary session, so the general do-not-improvise section owns it. The Waiting section is compared whole against its fixture and scoped to coordinators, so placing the rule there costs a fixture regeneration and narrows the rule to the wrong audience. The `This harness is` block is per-harness and fixture-bound, so the rule cannot live inside it either. Governs R1, R5, R7.
- KTD2. **The change is instruction-only. No CI gate observes the behavior.** The divergence exists only in the agent's tool calls, which the repository never receives. What CI can pin is the render: the paragraph's presence in every harness's shared body. The PR states this so nobody hunts for a gate that cannot exist. Governs R6, R8.
- KTD3. **The render is pinned by `NEEDLES` entries, not by a new fixture.** The shared-body needle loop is the established pin for a rule outside the fixture-bound sections, and a needle per load-bearing sentence catches a dropped MUST or MUST NOT. A fixture would bound the whole section and turn every later edit to the native-tools section into a fixture regeneration. Each needle quotes the final wording verbatim, so U2 lands only after U1's text is fixed. Governs R6.
- KTD4. **The wording is directional; the implementer finalizes it under the repository's writing rules.** Directional text: "When an invoked skill writes out a literal command for a long-running or backgrounded process, the agent MUST issue that command as the skill writes it, preamble included, on the first call and on every re-arm. A preflight step in that recipe — a scratch-root ownership or symlink test, a mode fix, an interpreter probe — MUST NOT be dropped, shortened, or replaced with a hardcoded value because an earlier call in the same session already satisfied it. A re-issued command that omits a preflight step because an earlier call's side effects remain is a new command, not the documented one. The only text the agent changes is a value the recipe leaves to the run, such as a path or an identifier; a prohibition in this file on a token in that command, such as bare `orca`, still governs that token." The final text keeps RFC 2119 terms, short sentences, and one idea per sentence, and keeps the four needle sentences recognizable. Governs R1, R2, R3, R4.

### Assumptions

- Placing the paragraph between line 61 and line 63 of the template touches no fixture-bound region: the `This harness is` and `This harness runs` fixtures match by line prefix, the two autonomy fixtures anchor to each other above this section, and the wait-section extractor starts at its own heading. U1's gate run is what settles this.
- A skill recipe's substitution placeholders, such as `SKILL_DIR`, a PR number, or a state-directory name, are the run's to fill and are not preamble. R4 names them so the rule does not read as a ban on filling them.
- `AGENTS.md:77` needs no edit: the new paragraph is one more unbounded shared-body paragraph pinned by needles, which is the shape that line already describes.

### Sequencing

U1 lands first because U2's needles quote U1's final sentences verbatim. Both are one change set: the gate is green with U1 alone and stays green with U2, and U2 is what makes a later deletion of the paragraph fail.

## Implementation Units

### U1. Add the shared re-arm paragraph to the instruction core

- **Goal:** Every harness render carries the rule as one shared paragraph in `## File edits and native tools`.
- **Requirements:** R1, R2, R3, R4, R5, R7.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`.
- **Approach:** Insert one paragraph after the "A script MAY perform a purely mechanical change" paragraph and before the `## Waiting on dispatched workers` heading, separated by blank lines like its neighbours (KTD1). Start from the directional text in KTD4 and finalize it under the repository's writing rules. Use no template action, no harness conditional, and no OS conditional, so the peer diff and the cross-OS diff both stay clean. Do not touch the `This harness is` block or any paragraph a fixture bounds.
- **Test scenarios:**
  - The three harness renders differ only in their `This harness is` and `This harness runs` lines.
  - The Linux and Darwin renders differ only in the executable rule.
  - Every fixture under `.ci/fixtures/agent-instructions/` is byte-identical to its committed content.
- **Verification:** `.ci/test-agent-instructions.sh` passes with no fixture edit.

### U2. Pin the paragraph with needles

- **Goal:** A render that loses the rule fails the instruction gate for each harness.
- **Requirements:** R6.
- **Dependencies:** U1.
- **Files:** `.ci/test-agent-instructions.sh`.
- **Approach:** Add four entries to the `NEEDLES` heredoc, quoting U1's final wording verbatim: the MUST sentence about issuing the command as written on every re-arm, the MUST NOT sentence about dropped or hardcoded preflight, the sentence that a re-issued command omitting preflight is a new command, and the substitution sentence (KTD3). Place them beside the existing native-tools needles so the heredoc keeps its section order. Add no fixture and no new comparison loop.
- **Test scenarios:**
  - With the paragraph present, the gate passes for `claude`, `codex`, and `omp`.
  - With the paragraph removed from the template, the gate fails on the first missing new needle and names it with the harness (AE3).
  - With one needle sentence reworded in the template but not in the heredoc, the gate fails on that needle.
- **Verification:** `.ci/test-agent-instructions.sh` passes, and the removal scenario above fails as described when tried locally and reverted.

## Verification Contract

| Check | Expected outcome | Proves |
|---|---|---|
| `.ci/test-agent-instructions.sh` | passes and prints `agent instruction gates passed` | R5, R6, R7: the paragraph renders identically across harnesses and OSes, the needles match, and every fixture comparison is unchanged |
| The same script with the paragraph temporarily removed | fails on the first missing new needle, naming it and the harness | R6: the pin is live, not vacuous |
| Diff of `.ci/fixtures/agent-instructions/` against the base branch | empty | R7 and KTD1: the paragraph landed outside every fixture-bound region |
| PR description | states the rule is instruction-only and carries `Closes #532` | R8 |

The CI workflow already runs `.ci/test-agent-instructions.sh`, so a green pipeline on the branch is the whole-plan signal.

## Definition of Done

### Global

- `.ci/test-agent-instructions.sh` passes on the branch, and the branch pipeline is green.
- The paragraph is present once in each harness render, outside the `This harness is` block and outside every fixture-bound section.
- No file under `.ci/fixtures/agent-instructions/` changed.
- The PR description carries `Closes #532` and the instruction-only statement (R8).
- No abandoned attempt survives: no fixture was added and reverted, no harness-conditional copy of the paragraph remains, and no partial needle whose text no longer matches the template is left in the heredoc.

### Per unit

- U1: the shared body of all three renders carries the final paragraph, and the gate passes with no fixture edit.
- U2: four needles quote the final paragraph verbatim, the gate passes, and removing the paragraph makes the gate fail on those needles.
