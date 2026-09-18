---
title: Four-Minute Orca Wait Checkpoint - Plan
type: chore
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/549
---

# Four-Minute Orca Wait Checkpoint - Plan

## Goal Capsule

- **Objective:** an Orca coordinator on Claude Code, Codex, or omp re-enters the model no more than four minutes after each blocking wait began. A Claude coordinator therefore lands on a warm five-minute prompt cache at every checkpoint instead of re-sending its whole context, every coordinator acts on an expired worker deadline or run bound within four minutes of expiry, and the wait keeps its shape: one blocking command per tool call, re-called while a dispatch is outstanding.
- **Means:** state the value once, as `--timeout-ms 240000` in the shared `## Waiting on dispatched workers` section, carve that one value out of the "called exactly as that guide writes it" rule without loosening it, split the native continuation layer from the Orca checkpoint layer, and cite the checkpoint from the coordinator dispatch contract (KTD4, KTD5, KTD6, KTD7).
- **Authority:** the three settled decisions (KTD1, KTD2, KTD3) outrank any wording this plan proposes. `AGENTS.md`'s rules that a reworded fixture-backed paragraph updates its fixture in the same commit and that the three harness renders match outside the `This harness is ` and `This harness runs ` paragraphs outrank tidiness. Every needle `.ci/test-agent-instructions.sh` asserts today is load-bearing and outranks any rewording that would drop one.
- **Execution profile:** instruction prose in two chezmoi templates plus the locked fixture and needles that pin it. There is no runtime code; the proof is the repository's gate scripts run locally.
- **Stop conditions:** stop and report if a required needle cannot survive the rewording, if the change would need a `This harness is ` paragraph to carry the value, or if any wording would set, shorten, or lengthen a worker deadline or the run's wall-clock bound.
- **Who finishes and ships:** this run implements, verifies, opens the pull request, and merges it once CI is green.

## Product Contract

### Summary

The shared `## Waiting on dispatched workers` section of `.chezmoitemplates/agents-instructions.tmpl` replaces the phrase "Keep the explicit Orca timeout" with the concrete value `--timeout-ms 240000`, four minutes, states that the value is one for every harness and why, and separates the Orca checkpoint from the harness's native continuation inside it. Its form rule keeps the sentence "called exactly as that guide writes it" verbatim and adds that this section owns exactly one value inside that spelling. The coordinator dispatch contract in `.chezmoitemplates/orchestration-coordinator.tmpl` cites that checkpoint and places it beside the worker deadline and the run's wall-clock bound, which keep their meaning and their text. The section fixture and the CI needles land in the same unit as each template edit.

### Problem Frame

The installed Orca guide writes its blocking wait as `check --wait ... --timeout-ms 900000`, a fifteen-minute interval, and the repository's coordinator instructions say only "Keep the explicit Orca timeout", so every coordinator runs the guide's figure. A Claude coordinator's prompt cache lives five minutes. A wait that returns after fifteen therefore re-enters the model on a cold cache and re-sends its whole context at every checkpoint, which is the cost issue #549 names. The same interval also decides how late a coordinator sees an expired worker deadline or run bound, because the shared section checks them at each native yield and before each repeat of the command. The repository's existing rules add tension a new number must resolve: the form rule says the wait is the guide's command "called exactly as that guide writes it", the execution paragraph says "use the longest permitted interval to minimize avoidable model requests", and the Codex harness paragraph says "use the largest blocking interval allowed by the active tool". Read naively, each of those forbids a four-minute value.

### Requirements

- R1. The shared wait section states the per-wait checkpoint as `--timeout-ms 240000`, four minutes, in the sentence that today reads "Keep the explicit Orca timeout and retain the returned command handle."
- R2. The value is one for every harness. The shipped text says so and gives the reason in place: the five-minute Claude prompt-cache TTL, and the bound it puts on how late any coordinator sees an expired deadline or run bound.
- R3. The worker's deadline and the run's wall-clock bound keep their meaning and their text. The checkpoint bounds one wait only and neither shortens nor lengthens the other two.
- R4. The wait keeps its shape: one blocking command per tool call, no shell control flow around it, and the same command called again while a dispatch is outstanding. The worked example block is unchanged.
- R5. The sentence "A wait on a dispatched Orca worker is the installed guide's blocking wait command, called exactly as that guide writes it." survives verbatim, and the text beside it authorizes exactly one substitution, the `--timeout-ms` value, and no other token.
- R6. The shipped text draws two layers apart by name: the Orca command's own `--timeout-ms` checkpoint, which is fixed, and a harness's native blocking continuation inside one checkpoint, which the coordinator still maximizes. The interval a harness paragraph tells a coordinator to maximize is named as the inner layer.
- R7. The coordinator dispatch contract names the four-minute checkpoint as the one value the run writes into the guide's wait spelling and places it against the deadline and the wall-clock bound.
- R8. Every needle `.ci/test-agent-instructions.sh` asserts today still matches, the wait-section fixture equals the rendered section for every harness on both OS branches, and the `This harness is ` fixtures are unchanged.

### Key Decisions

- **The cap is one value for every harness, 240000 ms.** Governs R2. The shared section is byte-identical across the three harnesses and fixture-locked, so one number there is a byte CI enforces for every coordinator, while a per-harness value would need three harness-paragraph edits, three fixture updates, and an indirection in the form rule. The interval's second effect is harness-neutral: it bounds how late any coordinator sees an expired worker deadline or run bound. The cost to a non-Claude coordinator is bounded and honest: a harness whose native continuation already returns to the model more often than every four minutes pays nothing extra, and one whose native wait spans the whole checkpoint in one request pays at most one short re-entry per empty four minutes. No verified prompt-cache TTL exists for Codex or omp to argue a different figure, and this plan asserts none; a figure chosen without one would be a guess. The reasoning ships in the section's first paragraph (U1).
- **The guide's enumeration heuristic is an accepted consequence, not addressed in text.** The installed guide says to enumerate with `worker-list` after three consecutive empty waits. At four minutes that fires after roughly twelve minutes of silence instead of roughly forty-five. The repository's instruction text never restates that heuristic, restating it would make this file a second owner of a guide rule, and the earlier firing is a benefit: the enumeration is one read-only query, a `none` `nextAction` returns the run to the same wait, and a worker that died silently is proven dead thirty-three minutes sooner. Governs nothing in the shipped text; recorded here so the implementer does not treat it as a gap.
- **The `This harness is ` paragraphs are not edited.** Governs R6, R8. The Codex sentence "use the largest blocking interval allowed by the active tool" is correct once the shared section names that interval as the native layer inside one checkpoint, and every harness reads the shared section in the same file. Editing the Codex line would add a fixture update for no rule change.

### Scope Boundaries

- No worker deadline or run wall-clock bound value is set anywhere; those stay per-run values the dispatch contract already requires.
- The installed Orca guide is external and unchanged; the shipped text names "the figure the guide prints" rather than `900000`, so a later guide figure needs no edit here.
- The worked example block in the wait section, the `harness-is-*.txt` and `harness-runs-*.txt` fixtures, the two autonomy fixtures, `.chezmoitemplates/orchestration-everyone.tmpl`, `AGENTS.md`, and `README.md` are untouched.
- `.chezmoiscripts/70-agents/run_onchange_after_update-claude-plugins.sh.tmpl` and `dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl` fingerprint the coordinator template, so the change reaches deployed hosts at the next apply with no hand edit; `packages/orchestration-hook/test/fixtures/payload/coordinator.md` is a stub body and needs no update.

### Assumptions

- A1. The section from `## Waiting on dispatched workers` to the next `## ` heading carries no template action, so the fixture is that section's bytes verbatim, heading through the trailing blank line, and the gate's render of any harness wrapper yields the same bytes.
- A2. `chezmoi` and `bun` are available on the implementing host; `.ci/test-orchestration-hook.sh` compiles the hook binary.
- A3. The gate's fixture comparison is a soft failure and its needles are hard failures, so a run reports both a drifted fixture and a lost needle in one pass. The fixture is regenerated after the final wording lands, never from an intermediate render.

## Planning Contract

### Key Technical Decisions

- KTD1. **The justification for the four-minute cap is the five-minute Claude prompt-cache TTL.** (session-settled: user-directed — chosen over justifying the cap on a one-hour prompt-cache TTL this harness's own tooling text asserts: the user directed that the one-hour harness content be ignored.) The shipped text states the five-minute TTL as the reason, without hedging and without the one-hour figure. Serves R1, R2.
- KTD2. **Only one wait interval is capped; the worker deadline and the run's wall-clock bound are untouched.** (session-settled: user-directed — chosen over lowering the deadline or the run bound alongside the interval: the timeout is a checkpoint that re-enters on a warm cache, not a shorter budget for the work.) Serves R3, R7.
- KTD3. **The wait shape stays: one blocking command per tool call, the same command re-called while a dispatch is outstanding.** (session-settled: user-directed — chosen over turning the shorter interval into a polling loop: the guide already treats a timeout as a checkpoint, and the form rule bans shell-control-flow waits outright.) Serves R4.
- KTD4. **The value has one owner: the first paragraph of the shared wait section.** `240000` appears once, in the sentence R1 names, because that paragraph is the execution policy every coordinator reads and the fixture pins it byte for byte. The form rule in the fourth paragraph and the coordinator contract refer to "the four-minute checkpoint" in words and never restate the flag value. Serves R1, R2, R7.
- KTD5. **The form rule keeps its needle sentence and gains a one-value carve-out.** The sentence R5 names is a shared-body needle, so it stays verbatim and a new sentence follows it: this section owns one value inside that spelling, the run writes the four-minute checkpoint fixed above into `--timeout-ms` in place of the figure the guide prints, the guide's figure yields to this file by the precedence rule above, and no other token changes, so the command's shape stays the guide's and the literal-command rule above governs every other token. That reconciles three rules at once: the precedence rule that a skill's instructions yield to this file, the literal-command rule that only a value the recipe leaves to the run changes, and the form prohibition, which stays whole because the carve-out names one flag's value and nothing else. Serves R4, R5.
- KTD6. **The two layers are named in the second paragraph, and the harness paragraphs stay as they are.** "A required blocking continuation on the same command is not a status poll; use the longest permitted interval to minimize avoidable model requests" becomes a sentence about the native continuation, followed by one that names it the inner layer: it runs inside one Orca checkpoint and never lengthens it, because the command returns at its own `--timeout-ms` whatever the harness does, and the blocking interval a harness paragraph tells a coordinator to maximize is this inner layer, never the checkpoint. A Claude coordinator's inner layer is one background `Bash` call that spans the checkpoint; a Codex coordinator's is its `write_stdin` continuation, which it still maximizes within the checkpoint. This is the distinction the prior plan `docs/plans/2026-09-13-1424-refactor-coordinator-background-waits-plan.md` drew in its KTD3 between an Orca command timeout, a native yield, and a turn ending, now stated in shipped text. Serves R6.
- KTD7. **Each template edit lands with its fixture and its needles in one unit.** U1 regenerates `.ci/fixtures/agent-instructions/waiting-on-dispatched-workers.txt`, adds one wait-execution needle for the value sentence, two shared-body needles for the carve-out and the layer sentence, and one BANNED entry for the retired numberless sentence, so the old wording cannot return through any render. U2 adds one coordinator needle for the citation. Needles prove presence; the fixture proves nothing else in the section moved. Serves R8.

### Sequencing

U1 before U2, because U2's citation names the checkpoint U1's wording fixes, and the gate that proves both is run once after U2.

## Implementation Units

### U1. Fix the four-minute checkpoint in the shared wait section

- **Goal:** every harness's rendered instruction file states the `--timeout-ms 240000` checkpoint, its reason, the one-value carve-out inside the form rule, and the inner-layer versus checkpoint split, and the fixture and needles that pin the section match it.
- **Requirements:** R1, R2, R3, R4, R5, R6, R8. Implements KTD1, KTD2, KTD3, KTD4, KTD5, KTD6, KTD7.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`, `.ci/fixtures/agent-instructions/waiting-on-dispatched-workers.txt`, `.ci/test-agent-instructions.sh`.
- **Approach:**
  1. In the section's first paragraph, replace "Keep the explicit Orca timeout and retain the returned command handle." with: "Pass the explicit Orca timeout as `--timeout-ms 240000`, a four-minute checkpoint, and retain the returned command handle. That value is one for every harness: four minutes keeps a Claude coordinator inside its five-minute prompt-cache TTL, so each checkpoint re-enters on a warm cache instead of re-sending the whole context, and it bounds for every coordinator how late an expired worker deadline or run bound is seen. A harness whose native continuation returns to the model more often than that pays nothing extra for it. The checkpoint bounds one wait and nothing else: the worker's deadline and the run's wall-clock bound keep their own values, and a return that carries no Delivery is a checkpoint, not a failure." Leave the paragraph's first and last two sentences as they are.
  2. In the second paragraph, replace "A required blocking continuation on the same command is not a status poll; use the longest permitted interval to minimize avoidable model requests." with: "A required native blocking continuation on the same command is not a status poll; use the longest native interval the harness permits, so one checkpoint costs as few model requests as the harness allows. That native interval is the inner layer: it runs inside one Orca checkpoint and never lengthens it, because the command returns at its own `--timeout-ms` whatever the harness does, and the blocking interval a harness paragraph tells a coordinator to maximize is this inner layer, never the checkpoint." Extend "Check worker deadlines and the run bound at each native yield" to "at each native yield and at each checkpoint return".
  3. In the fourth paragraph, keep its first sentence verbatim and insert after it: "This section owns one value inside that spelling: the run writes the four-minute checkpoint fixed above into `--timeout-ms` in place of the figure the guide prints, the guide's figure yields to this file by the precedence rule above, and no other token changes, so the command's shape stays the guide's and the literal-command rule above governs every other token." Leave the rest of the paragraph and the example block untouched.
  4. Regenerate the fixture as the section's bytes from its heading through the trailing blank line before `## Harness and model tuning`, per A1.
  5. In `.ci/test-agent-instructions.sh`, add the value sentence from step 1 to the `WAIT_EXECUTION_RULES` list, add the carve-out clause "the run writes the four-minute checkpoint fixed above into `--timeout-ms` in place of the figure the guide prints" and the layer clause "the blocking interval a harness paragraph tells a coordinator to maximize is this inner layer, never the checkpoint" to the `NEEDLES` list beside the existing form-rule needles, and add "Keep the explicit Orca timeout and retain the returned command handle." to the `BANNED` list.
- **Patterns to follow:** the section's existing dense normative style, RFC 2119 terms literal, em-dashes and inline code for identifiers; the `NEEDLES` and `BANNED` heredoc lists' one-string-per-line shape; the gate's header comment, which already explains that rewording the section means regenerating its fixture in the same commit.
- **Test scenarios:**
  - Rendering the Claude, Codex, and omp wrappers on linux and on darwin yields a `## Waiting on dispatched workers` section byte-identical to the regenerated fixture, six comparisons.
  - Each of the eight existing `WAIT_EXECUTION_RULES` substrings and the new value sentence match inside every rendered section.
  - The shared-body needles for the fourth paragraph and the example block still match in all three renders, including "called exactly as that guide writes it.", "One wait command is one tool call, and no shell control flow wraps it.", "That repetition holds only while the worker's own deadline and the run's wall-clock bound hold", "This rule governs the command's FORM.", and both `wait 1:` and `wait 2:` example lines.
  - The two new shared-body needles match in all three renders.
  - No render contains "Keep the explicit Orca timeout and retain the returned command handle." or "start the next wait, end the turn".
  - The `This harness is ` lines of every harness still equal `harness-is-claude.txt`, `harness-is-codex.txt`, and `harness-is-omp.txt`, which are not modified.
  - The linux and darwin renders of each harness differ only in the executable rule, and the three linux renders match outside their harness paragraphs.
  - The `lfg` and workflow-required autonomy paragraphs still render exactly two lines apart.
- **Verification:** `.ci/test-agent-instructions.sh` passes, and the section extracted from any of the six renders is byte-identical to the fixture.

### U2. Cite the checkpoint from the coordinator dispatch contract

- **Goal:** a lead reading only the injected coordinator payload learns that each rolling wait is the guide's command at the four-minute checkpoint, that the guide's figure yields, and that the checkpoint, the worker deadline, and the run bound are three separate bounds.
- **Requirements:** R3, R7, R8. Implements KTD2, KTD4, KTD7.
- **Dependencies:** U1.
- **Files:** `.chezmoitemplates/orchestration-coordinator.tmpl`, `.ci/test-agent-instructions.sh`.
- **Approach:**
  1. In the dispatch-contract paragraph, keep "the guide stays the source for exact command spellings" and extend the sentence: ", and the one value the run writes into its wait spelling is the four-minute `--timeout-ms` checkpoint the wait section of the user-scoped instruction file fixes." Follow it with: "That checkpoint bounds one wait, the deadline bounds one worker, and the wall-clock bound bounds the run; none of the three lengthens or shortens another."
  2. Leave every other sentence of the paragraph, including the deadline, wall-clock bound, stop-and-release, and OUTRANK sentences, byte for byte as it is; each is a coordinator needle.
  3. Add "the one value the run writes into its wait spelling is the four-minute `--timeout-ms` checkpoint" to the `COORDINATOR_NEEDLES` list in `.ci/test-agent-instructions.sh`.
- **Patterns to follow:** the paragraph's own style, which states obligations and names no version-specific command spelling; the coordinator template's header comment, which requires the body to stay harness-neutral and free of template actions beyond the roster lookups it already makes.
- **Test scenarios:**
  - The Claude coordinator payload renders on linux and darwin to identical bytes.
  - Every existing `COORDINATOR_NEEDLES` entry still matches, including "Every dispatched worker MUST carry an explicit deadline set before dispatch, and the run MUST hold a wall-clock bound across its rolling waits.", "At a worker's deadline the run MUST stop that worker, release it, and proceed on the artifacts it already holds", "When the run's own wall-clock bound expires the run MUST do the same for every dispatch still outstanding, then proceed.", and the OUTRANK sentence.
  - The new coordinator needle matches.
  - Every roster model id still appears in the rendered coordinator body, and the payload still carries no `fable` rung sentence.
  - The compiled hook binary delivers a coordinator body equal to the rendered template.
- **Verification:** `.ci/test-agent-instructions.sh`, `.ci/test-orchestration-hook.sh`, and `.ci/test-agent-roster.sh` pass.

## Verification Contract

| Check | Applies to | What it proves |
|---|---|---|
| `.ci/test-agent-instructions.sh` | U1, U2 | R1, R5, R6, R8 — six byte comparisons of the wait section against its fixture, every wait-execution, shared-body, and coordinator needle, the BANNED scan, the unchanged `harness-is-*` and `harness-runs-*` fixtures, cross-OS parity, and the autonomy-paragraph anchor |
| `.ci/test-orchestration-hook.sh` | U2 | the hook binary compiles and delivers the rendered coordinator body, so the citation reaches a lead session |
| `.ci/test-agent-roster.sh` | U2 | the coordinator body still renders against the committed roster and roster parity holds |
| Section extraction from a gate render, compared to the fixture | U1 | A1 — the fixture was regenerated from the final wording, not from an intermediate render |
| `git diff --check` and a diff limited to the four files U1 and U2 name plus this plan | U1, U2 | no whitespace error and no edit outside the requested scope, per `AGENTS.md` |

The fixture is regenerated by rendering `dot_claude/readonly_CLAUDE.md.tmpl` the way the gate does, `chezmoi --config <a toml holding only [data]> --source <repo root> --destination <scratch> --override-data '{"chezmoi":{"os":"linux"}}' execute-template`, with a stub `op` on `PATH`, and extracting from `## Waiting on dispatched workers` up to the next `## ` heading.

## Definition of Done

- The shared wait section states `--timeout-ms 240000`, four minutes, exactly once, with the five-minute Claude prompt-cache TTL and the deadline-visibility bound as its stated reasons, and says the value is one for every harness.
- The sentence "called exactly as that guide writes it" is present verbatim, followed by the one-value carve-out, and the example block is unchanged.
- The inner native layer and the Orca checkpoint are named as two layers, and the Codex and Claude harness paragraphs are unchanged.
- The coordinator dispatch contract cites the four-minute checkpoint and names the three bounds as separate; its deadline, wall-clock bound, and OUTRANK sentences are unchanged.
- U1: the regenerated fixture and the new needles land in the same commit as the template edit, and `.ci/test-agent-instructions.sh` passes.
- U2: the coordinator needle lands in the same commit as the template edit, and `.ci/test-agent-instructions.sh`, `.ci/test-orchestration-hook.sh`, and `.ci/test-agent-roster.sh` pass.
- No worker deadline or run bound value is set or changed anywhere, and no text restates the guide's enumeration heuristic.
- Cleanup: no scratch render, fixture copy, or temporary file remains in the worktree, and the diff is limited to the four implementation files and this plan.
