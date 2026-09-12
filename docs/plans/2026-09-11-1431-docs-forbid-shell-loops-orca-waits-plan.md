---
title: Forbid Shell Loops When Waiting on Orca Workers - Plan
type: docs
date: 2026-09-11
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/467
---

# Forbid Shell Loops When Waiting on Orca Workers - Plan

## Goal Capsule

- **Objective:** An operator who dispatches agents from this workstation gets a verdict within the deadline the run set, and keeps the machine responsive while the run waits — no run stalls for an hour behind a wait the operator never asked for.
- **Means:** State the wait FORM as a rule in the shared instruction core: the guide's blocking wait command is called as-is, one call per turn, and shell control flow is never the wait (KTD1, KTD2).
- **Authority:** The Product Contract wins on behavior. The KTDs win on mechanism. `AGENTS.md`'s render-verification rules and the shared instruction core bind every unit.
- **Execution profile:** Instruction text plus CI needles. The gates prove the rule is delivered, not that a coordinator obeys it; the Risks section states that limit.
- **Stop conditions:** Stop and report if the rule cannot be stated without pinning a version-specific Orca command spelling, or if any added text — a needle or the instruction prose itself — matches an entry on the gate's BANNED list.
- **Tail ownership:** The caller owns commit, push, and PR.

---

## Product Contract

### Summary

Add one rule to the shared body of `.chezmoitemplates/agents-instructions.tmpl`: a wait on a dispatched Orca worker is the guide's blocking wait command called as-is, one command per tool call, and never a shell loop. The rule names the forbidden forms — `for`, `while`, `until`, `sleep` polling, counting output files, listing processes — states that several outstanding workers mean calling the same command again on the next turn rather than looping, bounds that repetition by the deadlines the existing dispatch contract already sets, and carries a short example block showing the correct per-turn shape beside the forbidden ones. One sentence tying the rule to Claude Code's own background-execution and condition-watcher rules goes in that harness's paragraph rather than the shared body. Pin each clause with needles in `.ci/test-agent-instructions.sh`.

### Problem Frame

The instruction core and the coordinator payload both bound a dispatch: every worker carries a deadline, the run holds a wall-clock bound, and a settled worker is released in the turn that reads its `worker_done`. Neither states the SHAPE of the wait itself. The Claude harness paragraph comes closest — it requires the guide's blocking wait with its explicit timeout, run in the background — but it forbids only a poll on a timer and filler tool calls. A sentence that once forbade a `sleep` loop and a file-count poll was retired in an earlier rewording and now sits on the gate's BANNED list, so nothing in force today names those forms.

The gap is not theoretical. Issue #438 records two coordinators that hand-built `until [ "$(ls "$RUN_DIR"/*.json | wc -l)" -ge 7 ]; do sleep 20; done` and waited past 50 minutes for a peer that never wrote its artifact, leaving 8 `claude` and 3 `codex` processes resident at 5.4 GB. The loop is where the damage starts: the guide's wait receives every event for the whole run, so wrapping it per worker binds the window to one worker and leaves another worker's `escalation` or `question` unanswered; a shell loop holds the turn, so messages reach the session only after the command returns; and a hand-built exit condition discards the `--timeout-ms` checkpoint that would have ended the wait.

The orchestration guide invites the loop by saying only "Keep waiting until every expected Dispatch settles". That sentence is about persistence, not about shell shape, and an agent reading it alone fills the gap with a loop.

### Requirements

**Wait form**

- R1. A wait on a dispatched Orca worker calls the guide's blocking wait command as written, with no shell control flow around it.
- R2. One wait command is one tool call.
- R3. Building a wait from `for`, `while`, `until`, a `sleep` poll, a count of output files, or a process listing is forbidden.
- R4. Orca's own wait and query commands are the only authoritative source for a dispatch's lifecycle state while the run is waiting on it. This does not disturb the coordinator payload's end-of-run residency check, which keeps a host process sweep as a secondary signal.

**Several outstanding workers**

- R5. While the worker's deadline and the run's wall-clock bound both hold, a dispatch still outstanding after a wait returns means the run calls the same blocking wait command again rather than looping over workers.
- R6. Repetition happens across the run's turns, not inside a shell command.
- R7. Each wait call is read and acted on — reply, release, or wait again — before the next wait starts. A wait that returns a delivery is acknowledged on the next wait call, so an unacknowledged delivery is not replayed instead of new events.
- R14. When a worker's deadline or the run's bound expires, the run stops and releases rather than waiting again, and records the missing artifact as a gap. The existing deadline and release contract owns that path; this rule adds no second copy of it.

**Composition and presentation**

- R8. The rule states that it governs the command's FORM. A harness whose own instruction paragraph fixes HOW that command is run carries the sentence saying both apply; the shared rule itself names no harness-specific tool.
- R9. The ban reaches only a wait on a dispatched worker. A condition watcher is a different thing and is unaffected; where a harness directs one, that harness's own paragraph says so.
- R10. The rule carries a short example block contrasting the correct repeated call with the forbidden loop forms, with each correct call marked as its own turn.
- R11. The rule reaches every managed harness's instruction file through the shared body of `.chezmoitemplates/agents-instructions.tmpl`, and is synced only by editing that template and running `chezmoi apply`.

**Regression cover**

- R12. `.ci/test-agent-instructions.sh` asserts each clause of R1 through R10 and R14 by needle against the rendered targets — the harness-neutral clauses against every render's shared body, the harness-scoped sentence against its owning harness alone.
- R13. Neither a new needle nor any added instruction text matches an entry on the gate's BANNED list.

### Key Decisions

- **The rule lives in the shared body, not the coordinator payload.** Governs R11. Three things decide it together: #467's acceptance names the four rendered instruction files; the coordinator payload is delivered only to a lead in the one harness that leads, so a `codex` or `omp` session that ever coordinates would never receive it; and the shared core is the only delivery every managed harness receives unconditionally, with no session-role resolution in front of it. This narrows the earlier role-aware split rather than reversing it — the payload keeps the deadline, release, and residency contract, and gains no copy of this rule.
- **The wait mechanism stays unpinned to a command spelling.** Governs R1, R10. The instruction core deliberately carries no version-specific Orca subcommand, so the rule and its example refer to "the guide's blocking wait command" rather than reproducing it.
- **`Refs #438`, not `Closes #438`.** Two of #438's acceptance items stay open: filing two defects upstream in Orca's own repository, which an unattended run cannot do in a repository that is not the operator's, and naming a verification command for the no-resident-worker check, which the residency clause still leaves to the version-matched guide. This change advances #438's defect 1 only.

### Scope Boundaries

**In scope**

- The wait-form rule in the shared body of `.chezmoitemplates/agents-instructions.tmpl`, plus the one harness-scoped sentence in its Claude paragraph and the fixture that paragraph is compared against.
- Needles for that rule in `.ci/test-agent-instructions.sh`.

**Outside this change**

- The deadline, release, and residency clauses in `.chezmoitemplates/orchestration-coordinator.tmpl`. They already hold and this rule composes with them.
- Filing Orca defects 4 and 5 upstream. `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md` holds the filing-ready drafts; the operator files them.
- Any change to the orchestration guide's own text, which ships inside the Orca binary.

### Sources

- `.chezmoitemplates/agents-instructions.tmpl:46` — the Claude harness paragraph carrying the background-wait rule this one composes with.
- `.chezmoitemplates/orchestration-coordinator.tmpl` — the deadline, release, and residency contract.
- `.ci/test-agent-instructions.sh` — the needle and BANNED lists; the retired wait sentences sit in BANNED.
- `AGENTS.md`, "Agent surfaces and ownership" — the four renders must match outside the `This harness is ` / `This harness runs ` paragraphs and omp's payload block.
- `docs/plans/2026-09-08-2137-fix-orca-dispatch-review-contract-plan.md` — the prior plan that added the dispatch contract.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **State the rule as one shared-body paragraph plus one fenced example, in a new `## Waiting on dispatched workers` section placed between `## File edits and native tools` and `## Harness and model tuning`.** A new section keeps the rule out of the file-editing subject it does not belong to, and inserting it there disturbs no existing adjacency. The gate anchors the `lfg` autonomy paragraph and the workflow-required-step paragraph to each other two lines apart in `## Routing and mirrors`; both sit above the insertion point and are unaffected.
- KTD5. **Keep the shared section harness-neutral, and put the one harness-specific sentence in the Claude Code harness paragraph.** Governs R8, R9. The shared body must render byte-identical across all four targets, so a sentence naming `run_in_background: true` or `Monitor` there would hand Codex, Antigravity, and oh-my-pi a reference to an instruction and a tool they do not have. The shared rule therefore says only that a harness whose own paragraph fixes how the command is run keeps that rule alongside this one; the Claude paragraph carries the concrete composition and the condition-watcher carve-out.
- KTD2. **Write the example with a placeholder for the wait command, not a literal Orca invocation, and mark each correct call as its own turn.** Governs R1, R6, R10. The forbidden forms are shown verbatim, because naming them is the point. The correct form is a placeholder, so the example never pins a spelling the installed guide owns — and each occurrence carries a turn label, because two adjacent placeholders with no labels read as a two-line script, which is the shape the rule forbids.
- KTD3. **Use a `text` fence, not `sh`.** The block mixes a placeholder with real shell, so a shell language tag would claim the block is runnable.
- KTD4. **Add the harness-neutral needles to the shared `NEEDLES` heredoc and the harness-scoped sentence to `HARNESS_NEEDLES` under `claude`.** The shared list is asserted against every render's shared body; the harness list additionally proves no other harness received the Claude sentence, which is what the leak check exists for.

### Assumptions

- The rendered instruction files for `codex`, `agy`, and `omp` carrying an Orca wait rule is acceptable even though Antigravity does not dispatch. The shared body already carries Orca routing rules and states that Antigravity does not lead an Orca workflow.

### Risks

- The gates prove delivery, not obedience. A needle shows the sentence reached every rendered instruction file; nothing here observes a coordinator actually returning the turn and re-waiting. The same shape of prohibition was in force during the #438 incident by way of the orchestration guide, so presence alone is known not to be sufficient. This plan accepts that limit rather than inventing a gate that cannot measure it: the named, enumerated forbidden constructs and the worked example are the delta over the guide's prose, and the evidence that they work is the next unattended run's behavior, not CI.

### Sequencing

U1 writes the rule. U2 pins it. U2 depends on U1's exact wording.

---

## Implementation Units

### U1. Wait-form rule in the shared instruction core

- **Goal:** Every managed harness's instruction file states that an Orca worker wait is the guide's blocking command called as-is, one per tool call, never a shell loop.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R14
- **Dependencies:** none
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`, `.ci/fixtures/agent-instructions/harness-is-claude.txt`
- **Approach:**
  1. Insert a new `## Waiting on dispatched workers` section after the `## File edits and native tools` section and before `## Harness and model tuning`.
  2. Write one paragraph covering R1 through R9 and R14. Keep it in the shared body — no `{{ if eq .harness ... }}` branch, so all four renders stay byte-identical outside the harness paragraphs. Per KTD5 the paragraph names no harness-specific tool.
  3. Name the forbidden constructs explicitly: `for`, `while`, `until`, a `sleep` poll, counting files in an output directory, and listing processes. Then state R4's affirmative half: Orca's own wait and query commands are the only authoritative source for a dispatch's lifecycle state while the run waits on it, and the end-of-run residency sweep the coordinator payload already allows is untouched.
  4. State the several-workers rule as re-calling the same command on the next turn, that each call's result — `worker_done`, `escalation`, `question`, or timeout — is handled before the next wait starts, and that a delivery already read is acknowledged on the next call so the queue advances. Bound it per R14: repetition holds only while the worker's deadline and the run's wall-clock bound hold, and expiry routes to the existing stop-release-and-record-the-gap path rather than to another wait.
  5. State the composition harness-neutrally: this rule fixes the command's form, and a harness whose own paragraph fixes how the command is run keeps both. Say that the ban reaches a wait on a dispatched worker and not a condition watcher.
  6. Add the fenced `text` example below the paragraph. Show the placeholder wait once per turn with an explicit turn label on each occurrence and the event handled between them, then the forbidden loop forms under a "never" label.
  7. Extend the `This harness is Claude Code.` paragraph with the one harness-scoped sentence: that the background-execution rule it already states governs how the wait command runs while the new section governs its form, and that the `Monitor` until-loop it already directs is a condition watcher the ban does not reach.
- **Patterns to follow:** The paragraph shape and MUST/MUST NOT register of the existing `## File edits and native tools` body. The `sh` fence under `## Repository layout and garden ownership` for fence placement inside this template.
- **Test scenarios:** Test expectation: none — this unit is instruction text; U2 carries its regression cover.
- **Verification:** A scratch render of all four wrappers (`dot_claude/readonly_CLAUDE.md.tmpl` and the three `AGENTS.md` wrappers) contains the new section, only the Claude render carries the harness-scoped sentence, and the four renders still match outside the `This harness is ` / `This harness runs ` paragraphs and omp's payload block. `.ci/test-agent-instructions.sh` passes unchanged at this point, proving the insertion broke no existing fixture or adjacency assertion — including the `harness-is-claude.txt` fixture, which holds every `This harness is ` line for Claude whole and must be regenerated in the same commit as step 7's edit.

### U2. Needles pinning the wait-form rule

- **Goal:** A future edit cannot drop or reverse any clause of the wait-form rule without the gate failing.
- **Requirements:** R12, R13
- **Dependencies:** U1
- **Files:** `.ci/test-agent-instructions.sh`
- **Approach:**
  1. Add one needle per harness-neutral clause to the shared `NEEDLES` heredoc — the as-is call, the one-call-per-tool-call rule, the named forbidden constructs, Orca's commands as the authoritative state source while waiting, the re-call rule for several workers, the per-turn repetition, the handle-and-acknowledge-before-next-wait rule, the deadline bound on repetition, and the harness-neutral composition sentence.
  2. Add the harness-scoped sentence from U1 step 7 as a `claude`-owned row in the `HARNESS_NEEDLES` heredoc, so the gate proves Claude received it and the other three did not.
  3. Add one needle for a distinctive line of the example block, so the block cannot be deleted while the prose survives.
  4. Confirm no added text — needle or instruction prose — contains any `BANNED` entry as a substring. The gate greps each `BANNED` string against the whole rendered file, so a retired phrasing reappearing anywhere in the new section fails it, not only in the needle list.
- **Patterns to follow:** Existing entries in the shared `NEEDLES` heredoc — one verbatim sentence or clause per line, matched with `grep -F`. Existing `owner|needle` rows in `HARNESS_NEEDLES` for step 2.
- **Test scenarios:**
  - Unmodified repository: `.ci/test-agent-instructions.sh` exits 0 and prints `agent instruction gates passed`.
  - Delete the new paragraph from `.chezmoitemplates/agents-instructions.tmpl` in a scratch copy: the gate fails naming a lost rule, once per harness id.
  - Delete only the example block: the gate fails on the example needle while the prose needles still pass.
  - Reword one forbidden construct out of the list (drop `until`): the gate fails on that clause's needle.
  - Move the new shared paragraph into the Claude harness paragraph: the gate fails, because the shared-body scan strips harness lines before matching.
  - Move the harness-scoped sentence from the Claude paragraph into the shared body: the gate fails the leak check, because the sentence then appears in the other three renders.
  - Edit the Claude harness paragraph without regenerating `harness-is-claude.txt`: the gate fails on the whole-paragraph fixture comparison.
- **Verification:** `.ci/test-agent-instructions.sh` passes on the committed tree, and each scratch mutation above fails it with a message naming the dropped clause.

---

## Verification Contract

| Gate | Command | Applies to |
|---|---|---|
| Agent instruction render and needles | `.ci/test-agent-instructions.sh` | U1, U2 |
| Shell lint | `shellcheck .ci/test-agent-instructions.sh` | U2 |
| Scope check | `git diff --check` and a `git status` limited to the two files | U1, U2 |

Every render runs against a scratch destination with the stub `op`, an empty config, and `--source "$PWD"`, per `AGENTS.md`. The gate already implements that contract through `.ci/lib/render-gate-helpers.sh`; do not hand-roll a render.

---

## Definition of Done

- The shared body of `.chezmoitemplates/agents-instructions.tmpl` carries the harness-neutral wait-form rule and its example, the Claude harness paragraph carries the one harness-scoped sentence, and nothing else in the file changed.
- `.ci/test-agent-instructions.sh` asserts every clause of that rule and passes, and `harness-is-claude.txt` matches the edited Claude paragraph.
- The four rendered instruction targets differ only inside their own harness paragraphs and omp's payload block.
- No new text duplicates a rule the coordinator payload already owns.
- No experimental or abandoned wording is left in the diff.
- The PR description carries `Closes #467` and `Refs #438`, and names both items keeping #438 open: the upstream Orca filings drafted in `docs/residual-review-findings/2026-09-08-orca-dispatch-upstream-reports.md`, and the unnamed residency-verification command.
