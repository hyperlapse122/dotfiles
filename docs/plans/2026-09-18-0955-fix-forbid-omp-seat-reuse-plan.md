---
title: Forbid omp Seat Reuse Across Dispatches - Plan
type: fix
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/551
---

# Forbid omp Seat Reuse Across Dispatches - Plan

## Goal Capsule

- **Objective:** every omp worker an Orca lead dispatches judges from its brief and the repository alone. No worker carries a previous Unit's conversation, a failed approach, or a half-remembered edit into the next Unit, so a re-sent brief reproduces its result, failure reclassification and four-signal re-sizing rest on clean evidence, and the Orca app never shows a finished omp worker as still running between Units.
- **Means:** rewrite the omp launch paragraph of the coordinator template so the launch ceremony is paid on every dispatch, re-engaging a used omp terminal is prohibited, and a settled seat is released in the same turn; align the two prose files and the captured learning; re-pin the CI needles the wording moves (KTD1, KTD2, KTD3).
- **Authority:** the three settled decisions (KTD1, KTD2, KTD3) outrank any wording this plan proposes. `AGENTS.md` "Verification (never deploy live `$HOME`)" outranks any shortcut in a render check. Every needle `.ci/test-agent-instructions.sh` and `.ci/test-agent-roster.sh` assert today is load-bearing and survives, except the one dispatch-spelling needle in each script that this plan re-pins in the same unit as the template edit.
- **Execution profile:** instruction prose in one chezmoi template, two committed prose files, one learning, and the two gate scripts that pin the prose. No runtime code; the proof is the repository's gate scripts run locally.
- **Stop conditions:** stop and report if any needle other than the two dispatch-spelling needles cannot survive the rewording, if the two-branch template conditional cannot be kept with both branch strings verbatim, or if the change would need an edit to Cause 2 of the learning or to any file under `docs/plans/` other than this one.
- **Who finishes and ships:** this run implements, verifies, opens the pull request, and merges it once CI is green.

---

## Product Contract

### Summary

The omp launch paragraph of `.chezmoitemplates/orchestration-coordinator.tmpl` stops describing a standing seat. It says that every omp dispatch opens a new Orca terminal with the entry's model and thinking level, confirms the model, and dispatches into that terminal with `worker-start --task <task_id> --terminal <handle>`. It prohibits re-engaging an omp terminal a previous Dispatch ran in, names the seat a release target the moment its Dispatch settles under the same-turn release rule the review-and-peer contract already states, keeps the end-of-run residency check as the backstop, and classifies a launch that yields no seat. The matching sentence in `AGENTS.md`, the `### Launch ceremony` entry in `CONCEPTS.md`, and a dated supersession note in the seat-starvation learning follow the same rule. The gate needles that pin the old dispatch spelling move with the template edit, and a negative assertion keeps the retired sentences out of the coordinator payload.

### Problem Frame

The coordinator paragraph at `.chezmoitemplates/orchestration-coordinator.tmpl` line 53 tells the lead to launch one omp seat per shape per run and re-engage it for every later dispatch of that shape. The same template's first rule says a subagent inherits no conversation history, so a dispatch prompt MUST be self-contained. A reused seat contradicts that rule by construction: the worker still holds the previous Unit's transcript, so contaminated state propagates, context accumulates until compaction fires, and the same brief gives different results depending on seat state. The reuse exists because `docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md` diagnosed per-dispatch launch ceremony as one of two causes that starved the omp routing rows. Issue #551 decides that isolation wins over that saving and sends the cost question to issue #550.

### Requirements

**Coordinator rule**

- R1. Every omp dispatch opens a new Orca terminal running omp with the entry's model and thinking level, confirms the model from the terminal, and dispatches into that terminal, so the launch ceremony is paid per dispatch and never once per seat per run.
- R2. Re-engaging an omp terminal a previous Dispatch ran in is prohibited, whether or not that Dispatch has settled.
- R3. The dispatch call is spelled `worker-start --task <task_id> --terminal <handle>` wherever the shipped text spells it, and the text keeps saying that `worker-start` requires `--task` or `--spec`, so a bare `--terminal` is rejected before the seat receives work.
- R4. An omp seat is released when its Dispatch settles, in the same turn that reads the settlement, under the same-turn release rule of the review-and-peer contract. The exception that kept a standing seat out of that rule is gone.
- R5. The end-of-run residency check stays the backstop that proves no omp seat outlives the run.
- R6. A launch that yields no live seat with the confirmed model is classified in the shipped text and is not left to the three-consecutive-failure count.
- R7. The sentences "omp's own `modelRoles` then never decides which Gemini seat a dispatch uses." and "The version-matched Orca guide owns the exact terminal-launch spelling." survive verbatim.
- R8. The two-branch template conditional over the mechanical and implementation entries survives, and both rendered branch strings stay byte-identical to today's.

**Prose and learning parity**

- R9. The `AGENTS.md` sentence that begins "An omp seat is launched once per shape per run" states the per-dispatch launch, the prohibition, and release on settlement, and names no model id the roster does not declare.
- R10. The `### Launch ceremony` entry in `CONCEPTS.md` states that an omp seat pays the ceremony on every dispatch, spells the dispatch call as R3 does, and no longer says `worker-start --terminal` alone.
- R11. The seat-starvation learning carries a dated supersession note scoped to Cause 1 and to the "A Third Fact" section. Cause 2, its fix, and every file under `docs/plans/` other than this plan stay as they are.

**Gates**

- R12. Every needle `.ci/test-agent-instructions.sh` and `.ci/test-agent-roster.sh` assert matches after the change, the retired reuse sentences are asserted absent from the coordinator payload, and no unit leaves the tree red.

### Key Decisions

- **Claude and Codex rows need no prohibition.** Governs R1, R2. The same template says "Model and effort apply to a fresh agent terminal only", and `worker-start --model` and `--effort` launch a fresh agent terminal per dispatch for those agents. omp was the only harness with a standing-seat concept because those flags do not forward to it, so the prohibition is scoped to omp and the shipped text says so in one clause.
- **Launch cost is deferred to issue #550.** Governs nothing in the shipped text. Issue #551 sends the cost question there, and this plan proposes no launch shortcut.
- **History is not rewritten.** Governs R11. `docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md` (KTD6, R19 to R21, AE8) records a decision that was correct when made and stays untouched; the learning gets a supersession note in the form `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md` already uses.

### Scope Boundaries

- The routing table, the sizing paragraph, the brief-guidance table, the model-elevation paragraphs, and the review-and-peer contract paragraph keep their text. The new rule cites the contract's same-turn release rule and does not restate or extend its deadline and wall-clock-bound clauses.
- `README.md` carries none of the retired sentences and is untouched. `.ci/fixtures/agent-instructions/` holds fixtures for `.chezmoitemplates/agents-instructions.tmpl` only, so no fixture changes. No release-lock refresh belongs in this change.
- The installed Orca guide is external and unchanged; the shipped text keeps deferring the exact terminal-launch spelling to it.

### Acceptance Examples

- AE1. **Covers R1, R2, R4.** Given a run whose second Unit is implementation-shaped and whose first Unit's omp seat has settled, when the lead dispatches the second Unit, then it has already released the first terminal in the turn that read the settlement and opens a new terminal for the second Unit; it never passes the first terminal's handle to `worker-start` again.
- AE2. **Covers R6.** Given an omp launch whose terminal does not come up or whose confirmed model is not the entry's, when the lead classifies it, then it counts no failure against the Unit, advances no row, launches once more, and treats a second miss as agent unavailability for that dispatch, which the row's unavailable column already handles.
- AE3. **Covers R8.** Given a roster stub with one omp entry carrying both shapes at one pair, when the coordinator body renders, then it contains "one seat (`google-antigravity/gemini-3.8-flash` at `high`) for mechanical and implementation work alike" and not "for mechanical work, ".
- AE4. **Covers R12.** Given a coordinator payload that still contains "re-engages that terminal" or "standing seat", when `.ci/test-agent-instructions.sh` runs, then it fails naming the retired reuse rule.

### Sources

- `.chezmoitemplates/orchestration-coordinator.tmpl` line 34 (self-contained dispatch rule), line 47 (mechanical failure and unavailable-agent handling), line 53 (the paragraph to rewrite), line 55 ("Model and effort apply to a fresh agent terminal only"), line 66 (same-turn release rule and end-of-run residency check). Its header comment, lines 1 to 9, requires hand-written prose with ids from `agents.roster` and no template actions beyond the established conditional.
- `.ci/test-agent-instructions.sh` lines 541 to 546 (negative-assertion pattern), lines 623 to 652 (`CLAUDE_COORDINATOR_NEEDLES`, the four pinned fragments at lines 629 to 632).
- `.ci/test-agent-roster.sh` lines 298 to 335 (the `worker-start --terminal` needle at line 302, the two branch strings at lines 316 to 319 and 332 to 335), line 461 (two-entry stub branch string), lines 464 to 510 (prose model-id scan over `README.md` and `AGENTS.md`).
- `AGENTS.md` line 74, `CONCEPTS.md` lines 88 to 89.
- `docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md`, "## The Fix" Cause 1 paragraph and "## A Third Fact, Caught Only by Cross-Model Review".
- `.chezmoiscripts/70-agents/run_onchange_after_update-claude-plugins.sh.tmpl` line 21 and `dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl` lines 28 to 30 both fingerprint the coordinator template.
- Prior comparable change: commit `f928deaf`, which touched two templates, one fixture, and the instruction gate, and no release lock.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Re-engaging an existing omp terminal with `worker-start --task <task_id> --terminal <handle>` is prohibited.** (session-settled: user-directed — chosen over keeping the standing-seat reuse optimization: a reused seat carries the previous Unit's conversation history, which breaks the self-contained-dispatch rule, propagates contaminated state, and drifts after compaction.) Serves R2, R3. Conflict, recorded and not resolved away: the standing seat exists because `docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md` diagnosed per-dispatch launch ceremony as Cause 1 of a starved omp row, four lead calls against one for the codex neighbour. This change re-opens that pressure and proceeds anyway as suboptimal-but-workable. What still holds the omp rows, and what this change leaves alone: the routing table's membership rule that makes omp the default recipient of every Implementation Unit no recorded signal places at the `claude` rung, and the sizing paragraph's clause that an unrecorded `claude` implementation dispatch is a rule violation. The launch cost itself is deferred to issue #550 as follow-up work.
- KTD2. **Every dispatch launches a new omp terminal, and a settled dispatch's seat is a release target.** (session-settled: user-directed — chosen over releasing only at run end while reusing in between: without release-on-settle the seat stays available for reuse, which re-creates the prohibited path.) Serves R1, R4, R5. The release runs in the turn that reads the settlement, before the run acknowledges the Delivery and before it waits again, exactly as the contract already states for a judgment dispatch.
- KTD3. **The dependent release exception is rewritten with the launch paragraph.** (session-settled: user-directed — chosen over changing only the launch paragraph: a stale exception would contradict the new rule.) Serves R4. The sentences "A standing seat is not released at its Dispatch's settlement" and "Every standing omp seat is released before the run ends" are retired, and the template no longer places the mechanical and implementation rows outside the same-turn release rule.
- KTD4. **The no-failure classification survives, rebound from a gone seat to a failed launch, and bounded at one relaunch.** Serves R6. With no standing seat there is nothing to find gone, but a launch can still yield no live terminal or a terminal whose confirmed model is not the entry's. Such a launch happens before any brief is delivered, so it is not a failure of the Unit: it advances no row, adds nothing to the three-consecutive-failure count, and the lead launches once more. A second launch that yields no seat is agent unavailability for that dispatch, which line 47's unavailable-agent rule already routes to the next agent in the row. The bound exists because a per-dispatch ceremony with an unbounded no-failure relaunch could loop, and routing the second miss to an existing rule adds no new mechanism.
- KTD5. **The new paragraph cites the same-turn release rule; it does not restate it.** Serves R4. The review-and-peer contract paragraph owns the release rule, its receipt handling, and the residency check, and its text is unchanged. The launch paragraph says that rule binds an omp seat of the mechanical and implementation rows exactly as it binds a judgment dispatch. The contract's deadline and wall-clock-bound clauses are not extended by this change.
- KTD6. **The two-branch conditional keeps both branch strings verbatim, and "seat" names the terminal one Dispatch runs in.** Serves R8. `.ci/test-agent-roster.sh` pins the two-seat string at line 316, the one-seat string at lines 318 and 332, and the two-entry stub string at line 461, so the strings inside the conditional do not change. Rendered on the one-seat branch, "one seat (…) for mechanical and implementation work alike" now reads as one launch pair serving both shapes, which is what the sentence around it says.
- KTD7. **Each needle edit lands in the unit that causes it, and a negative assertion keeps the retired sentences out.** Serves R12. U1 replaces the dispatch-spelling needle at `.ci/test-agent-instructions.sh` line 630 with the `--task` spelling, replaces the `worker-start --terminal` needle at `.ci/test-agent-roster.sh` line 302 with the same spelling, and adds a loop over both coordinator renders in the shape of lines 541 to 546 that fails on `re-engages that terminal`, `standing seat`, or `standing omp seat`. The bare word "standing" is not banned because line 66 contains "outstanding".
- KTD8. **The learning gets a dated blockquote note, not a `superseded: true` frontmatter flag.** Serves R11. The selinux learning's flag marks a whole document as no longer current; here Cause 2 and its fix still describe current behavior, so the note is scoped in its first bold words to Cause 1 and the Third Fact, and the frontmatter gains only `last_updated: 2026-09-18` as three sibling learnings in the same directory already carry.

### Sequencing

U1 first, because U2 and U3 quote the dispatch spelling and the release rule U1 lands. U2 and U3 are independent of each other and may land in either order.

---

## Implementation Units

### U1. Rewrite the omp launch paragraph and re-pin its gates

- **Goal:** the rendered coordinator payload states the per-dispatch launch, the reuse prohibition, release on settlement, the residency backstop, and the launch-miss classification, and both gate scripts pass against it.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R12. Implements KTD1, KTD2, KTD3, KTD4, KTD5, KTD6, KTD7.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/orchestration-coordinator.tmpl`, `.ci/test-agent-instructions.sh`, `.ci/test-agent-roster.sh`.
- **Approach:**
  1. Replace line 53 of the template with one paragraph. Keep the first clause and the template conditional byte for byte; the text before the conditional changes from "the first launch of a seat is the ceremony this costs once — the lead opens an Orca terminal running omp" to "every omp dispatch pays the launch ceremony — the lead opens a new Orca terminal running omp". The text after the conditional reads: "— confirms the model from the terminal, and dispatches with `worker-start --task <task_id> --terminal <handle>`. That terminal is the seat of that one Dispatch and of no other: the lead MUST NOT re-engage an omp terminal a previous Dispatch ran in, settled or not, because the terminal holds the previous Unit's conversation history and a dispatch prompt MUST be self-contained. `worker-start` requires `--task` or `--spec`, so a bare `--terminal` is rejected before the seat receives work. When its Dispatch settles, the seat is a release target and never a reuse target: the same-turn release rule of the review-and-peer contract below binds an omp seat of the mechanical and implementation rows exactly as it binds a judgment dispatch, so the release runs in the turn that reads the settlement and is never collected for the end of the run. A launch that yields no live seat with the confirmed model is not a failure of the Unit: it advances no row, adds nothing to the three-consecutive-failure count, and the lead launches once more; a second launch that yields no seat is agent unavailability for that dispatch, which the row's unavailable column already handles. The end-of-run residency check below stays the backstop that proves no omp seat outlives the run. omp's own `modelRoles` then never decides which Gemini seat a dispatch uses. The version-matched Orca guide owns the exact terminal-launch spelling."
  2. In `.ci/test-agent-instructions.sh`, inside `CLAUDE_COORDINATOR_NEEDLES`, replace the line ``confirms the model from the terminal, and dispatches with `worker-start --terminal <handle>`.`` with ``confirms the model from the terminal, and dispatches with `worker-start --task <task_id> --terminal <handle>`.``, and add ``the lead MUST NOT re-engage an omp terminal a previous Dispatch ran in, settled or not`` and ``When its Dispatch settles, the seat is a release target and never a reuse target`` as two new needles. Leave the other three pinned fragments as they are.
  3. Directly after the `CLAUDE_COORDINATOR_NEEDLES` heredoc, add a loop over `"$coordinator_claude_linux"` and `"$coordinator_claude_darwin"` in the shape of the everyone-payload loop at lines 541 to 546 that fails with "contains retired omp seat-reuse rule" when `grep -F` finds `re-engages that terminal`, `standing seat`, or `standing omp seat`.
  4. In `.ci/test-agent-roster.sh` line 302, replace the needle `worker-start --terminal` with `worker-start --task <task_id> --terminal <handle>`, and reword the comment above it from "the omp seat is chosen by launching the terminal with that entry's model" to say the terminal is launched per dispatch with that entry's model. Leave lines 316 to 335 and 461 unchanged.
- **Patterns to follow:** the paragraph's own dense normative register with literal MUST and MUST NOT; the heredoc needle lists' one-string-per-line shape; the negative loop at lines 541 to 546; the template header comment's rule that the body carries no template action beyond the roster lookups and the existing conditional.
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh`: the three unchanged `CLAUDE_COORDINATOR_NEEDLES` fragments at lines 629, 631, and 632 still match the Claude coordinator render; the replaced dispatch-spelling needle and the two new needles match; the new negative loop finds none of its three strings in either coordinator render; every roster model id from the `agent-roster-validate.tmpl` render still appears in the body; the linux and darwin coordinator renders remain identical outside the executable rule.
  - `.ci/test-agent-instructions.sh` self-check of the negative loop, run once by hand before committing: a scratch copy of the linux coordinator render with the old line 53 appended makes the new loop fail, so the assertion can fail.
  - `.ci/test-agent-roster.sh`: the replaced needle at line 302 matches; the mechanical model id appears in the body; the committed roster renders "`google-antigravity/gemini-3.8-flash` at `low` for mechanical work, `google-antigravity/gemini-3.8-flash` at `high` otherwise" and not the one-seat string; the one-seat stub at lines 323 to 335 renders the one-seat string and no `for mechanical work, `; the two-entry stub at line 461 renders its two-seat string; the routing table still counts four rows and the brief table six.
  - `.ci/test-orchestration-hook.sh`: the compiled hook still finds the `orchestration-coordinator:begin` marker in the assembled payload.
- **Verification:** `.ci/test-agent-instructions.sh`, `.ci/test-agent-roster.sh`, and `.ci/test-orchestration-hook.sh` pass.

### U2. Align the committed prose

- **Goal:** `AGENTS.md` and `CONCEPTS.md` state the per-dispatch rule with the correct dispatch spelling, and the prose model-id scan stays green.
- **Requirements:** R9, R10, R12. Implements KTD1, KTD2.
- **Dependencies:** U1.
- **Files:** `AGENTS.md`, `CONCEPTS.md`.
- **Approach:**
  1. In `AGENTS.md` line 74, replace the sentence "An omp seat is launched once per shape per run, with the entry's model and thinking level pinned on the launch command, re-engaged with `worker-start --task <task_id> --terminal <handle>` while it stands, because `worker-start` requires `--task` or `--spec`, and released before the run ends, so `modelRoles` never decides which Gemini seat a dispatch receives." with "An omp seat is launched once per dispatch, with the entry's model and thinking level pinned on the launch command, given its one Dispatch with `worker-start --task <task_id> --terminal <handle>` because `worker-start` requires `--task` or `--spec`, never re-engaged by a later dispatch, and released in the turn its Dispatch settles, so `modelRoles` never decides which Gemini seat a dispatch receives." Change nothing else in the paragraph.
  2. In `CONCEPTS.md`, replace the body of `### Launch ceremony` with: "The number of lead tool calls a dispatch costs before the recipient can be given work. It is not uniform across the roster: `worker-start` carries model and effort for Claude, Codex, and Cursor launches, so those cost one call every dispatch, while an omp seat pays the full ceremony — a terminal launch, a handle read, and a model confirmation — on every dispatch, and then takes its one Dispatch with `worker-start --task <task_id> --terminal <handle>`; no later dispatch re-engages it, because it is released in the turn its Dispatch settles. Ceremony decides which row a lead actually picks when two rows are equally eligible, so a routing rule that leaves it uneven is re-decided on every dispatch regardless of what the table declares; the omp rows hold against that pressure by being the default membership for every Implementation Unit and by the rule that an unrecorded `claude` implementation dispatch is a violation."
- **Patterns to follow:** the surrounding sentences' register in each file; `CONCEPTS.md` entries are one paragraph under an H3 with no lists.
- **Test scenarios:**
  - `.ci/test-agent-roster.sh` lines 483 to 488: every model id extracted from `README.md` and `AGENTS.md` is in the roster allowlist, which holds because the new sentence names no model id.
  - `.ci/test-agent-roster.sh` lines 503 to 510: none of `codex-astra`, `seven worker`, `omp-flash-lite`, `five worker` appears in either prose file.
  - `grep -n 're-engage\|standing seat' AGENTS.md CONCEPTS.md` returns only the two new sentences' "never re-engaged" and "no later dispatch re-engages it" clauses, and no "standing seat".
- **Verification:** `.ci/test-agent-roster.sh` passes.

### U3. Record the supersession in the seat-starvation learning

- **Goal:** a reader of the learning sees that Cause 1's fix was reverted by issue #551 and why, without any rewrite of the recorded history and with Cause 2 untouched.
- **Requirements:** R11. Implements KTD8.
- **Dependencies:** U1.
- **Files:** `docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md`.
- **Approach:**
  1. Add `last_updated: 2026-09-18` to the frontmatter directly below `date:`. Do not add `superseded: true`.
  2. Directly after the "**Cause 1 — ceremony moved from per-dispatch to per-run.**" paragraph under "## The Fix", insert a blockquote: "> **Superseded on 2026-09-18, cause 1 only.** Issue #551 forbids omp seat reuse: every dispatch opens a new omp terminal, takes its one Dispatch with `worker-start --task <task_id> --terminal <handle>`, and is released in the turn that Dispatch settles, so the ceremony is per dispatch again and the same-turn release exemption is gone. The pressure this cause describes is now held by the cause 2 fix alone — the omp row's default membership and the recorded-signal rule for a `claude` implementation dispatch — and the launch cost is tracked in issue #550. Cause 2 and its fix stand as written."
  3. At the end of "## A Third Fact, Caught Only by Cross-Model Review", insert a blockquote: "> **Updated 2026-09-18.** The re-engage call this section corrects is retired by issue #551. The corrected spelling survives as the one dispatch call into a freshly launched terminal, and the lesson stands: an argv acceptance check is a different guarantee from a render."
  4. Change nothing under "### 2. A vacuous sizing band", "**Cause 2**", "## Why This Works", "## Prevention", or "## Related Issues".
- **Patterns to follow:** the blockquote note at `docs/solutions/security-issues/selinux-user-scope-agent-config-protection.md` line 31, bold date first, then the scope, then what still holds.
- **Test scenarios:**
  - `git diff -- docs/solutions/integration-issues/omp-seat-starvation-launch-ceremony-vacuous-sizing-band.md` shows exactly one added frontmatter line and two added blockquotes, and no removed line.
  - `git diff --stat -- docs/plans/` shows only this plan.
- **Verification:** `git diff --check` reports nothing, and the scoped diff above matches.

---

## Verification Contract

| Check | Applies to | What it proves |
|---|---|---|
| `.ci/test-agent-instructions.sh` | U1 | R3, R7, R12 — the three unchanged coordinator fragments, the re-pinned dispatch spelling, the two new needles, the negative loop over both coordinator renders, roster model ids, and cross-OS parity |
| `.ci/test-agent-roster.sh` | U1, U2 | R8, R9, R12 — the re-pinned seat-selection needle, both branch strings on the committed roster and on the one-seat and two-entry stubs, the four-row and six-row table counts, and the prose model-id scan of `AGENTS.md` |
| `.ci/test-orchestration-hook.sh` | U1 | the hook binary compiles and the assembled payload carries the coordinator marker |
| A scratch render of the coordinator body, read once by the implementer | U1 | the rewritten paragraph reads correctly on the committed two-seat branch, with the conditional intact |
| `git diff --check`, `git status`, and a diff limited to the six files U1 to U3 name plus this plan | U1, U2, U3 | no whitespace error and no edit outside the requested scope, per `AGENTS.md` |

The scratch render follows the mandatory contract in `AGENTS.md` "Verification": a per-user scratch directory, a stub `op`, an empty config, a throwaway destination, `--source "$PWD"`, and a `PATH` of the stub directory and the system directories only. The gates already do this through `render()` in `.ci/lib/render-gate-helpers.sh`; the hand render below uses the same wrapper the instruction gate writes at its line 139.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
printf '%s\n' '{{- includeTemplate "orchestration-coordinator.tmpl" (dict "ctx" . "harness" "claude") -}}' > "$scratch/coordinator.md.tmpl"
chezmoi_bin=$(command -v chezmoi)
env PATH="$scratch/bin:/usr/bin:/bin" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < "$scratch/coordinator.md.tmpl"
```

### Operational notes

- `.chezmoiscripts/70-agents/run_onchange_after_update-claude-plugins.sh.tmpl` fingerprints the coordinator template, so the next `chezmoi apply` on every managed host reruns the plugin updater. `dot_local/share/dotfiles-claude-plugin/dot_claude-plugin/plugin.json.tmpl` digests the rendered payload bodies into the plugin version, so that version moves and `claude plugin update` re-resolves it. Both are the designed propagation path and are disclosed, not worked around.
- No fixture under `.ci/fixtures/agent-instructions/` changes, and `.chezmoidata/releases.json` is not refreshed.

---

## Definition of Done

- The coordinator paragraph states the per-dispatch launch, prohibits re-engaging a used omp terminal, names a settled seat a release target under the contract's same-turn release rule, keeps the residency check as backstop, classifies a launch that yields no seat with a one-relaunch bound, and keeps the `modelRoles` and Orca-guide sentences verbatim.
- The template conditional and both of its branch strings are byte-identical to today's, and the rendered body contains neither "re-engages that terminal" nor "standing seat".
- KTD1 in this plan carries the starvation conflict call-out, and the shipped text nowhere reintroduces per-run seat reuse.
- `AGENTS.md` and `CONCEPTS.md` state the same rule with the `--task` spelling, and `CONCEPTS.md` no longer says `worker-start --terminal` alone.
- The learning carries the two dated notes and `last_updated`, and Cause 2, `docs/plans/2026-09-18-0015-refactor-gemini-first-worker-roster-plan.md`, and every other file under `docs/plans/` are unchanged.
- U1: the template edit, the two needle replacements, the two new needles, and the negative loop land in one commit, and `.ci/test-agent-instructions.sh`, `.ci/test-agent-roster.sh`, and `.ci/test-orchestration-hook.sh` pass.
- U2: `.ci/test-agent-roster.sh` passes with the prose edits in place.
- U3: the scoped diff shows only additions to the learning.
- Cleanup: no scratch render or temporary wrapper remains in the worktree, and the diff is limited to the six implementation files and this plan.
