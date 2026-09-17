---
title: Opus Lead With Fable Elevation Default - Plan
type: feat
date: 2026-09-17
topic: opus-lead-fable-elevation-default
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Opus Lead With Fable Elevation Default - Plan

## Goal Capsule

- **Objective:** An operator's everyday Claude Code and Orca lead sessions run on `opus[1m]`, so the Fable quota is spent only where its reasoning pays: the plan-authoring step of `ce-plan` and the approach-generation step of `ce-brainstorm`, which reach Fable by default in every repository that has not chosen a model of its own.
- **Means:** Move the roster's lead pin to `opus[1m]`, add one user-scoped instruction rule that resolves an unset `plan_model` or `brainstorm_model` as `fable`, route that elevation through the roster's `claude-fable` worker inside Orca, and remove the orchestration restrictions that bind a session outside Orca.
- **Product authority:** the user's decisions recorded in Key Decisions.
- **Execution profile:** four Implementation Units, each landing as one commit; CI is the acceptance gate.
- **Stop conditions:** a rendered instruction file or payload whose needle test fails is a stop until the needle and the text agree; a second `chezmoi apply` that changes a target is a stop.
- **Who finishes:** the implementing run ships every unit; no follow-up run is planned.
- **Open blockers:** none.

---

## Product Contract

**Product Contract preservation:** Product Contract unchanged.

### Summary

The lead pin and the Claude Code default become `opus[1m]` again, and Fable is reached through Compound Engineering's own model elevation instead of being the session model. A user-scoped instruction rule supplies `fable` as the elevation default whenever the repository's CE config leaves `plan_model` or `brainstorm_model` unset. In an Orca lead session that elevation is an Orca dispatch to the `claude-fable` judgment worker, which authors the plan file itself. Outside Orca the instruction files stop restricting subagents, bundled runners, and agent CLIs, so CE's elevation adapters run as shipped.

### Problem Frame

The roster plan (`docs/plans/2026-09-16-2329-feat-orca-lead-dispatch-only-model-roster-plan.md`) pinned the lead and the Claude Code default to `fable[1m]` so the lead's own judgment would be Fable-grade. In practice every turn of dialogue, every read, every brief, and every verification command now draws on the Fable quota, and the quota runs out long before the reasoning-heavy steps that justified the pin.

Compound Engineering already has the right seam: `ce-plan` and `ce-brainstorm` elevate one step to a chosen model, resolved from live intent, a caller carrier, then the repository's `.compound-engineering/config.local.yaml` and `config.yaml`. It has no user-level layer, so a repository that declares nothing gets no elevation, and the user-scoped instruction files currently forbid every adapter that elevation would use outside Orca.

### Key Decisions

- **The lead pin and the Claude Code default become `opus[1m]`.** Quota, not capability, decides the session model. (session-settled: user-directed — chosen over keeping `fable[1m]`, the roster plan's pin: the Fable quota runs out on mechanical turns) Governs R1.
- **The Fable default lives in the user-scoped instruction core, not in CE files or per-project config.** It reaches every harness instruction file and leaves CE untouched. (session-settled: user-directed — chosen over overlaying CE's elevation reference with a user-level config layer and over rendering `config.local.yaml` into every garden project: an overlay drifts on each CE bump, and a per-project render erases the "when the repo declares nothing" condition) Governs R3, R4.
- **Inside Orca, plan authoring elevates by dispatching the `claude-fable` worker, which writes the plan file.** The lead boundary gets its one Markdown exception. (session-settled: user-directed — chosen over a worker that returns only the body for the lead to write and over the lead authoring on opus in place: a body handoff costs tokens twice and risks re-narration, and opus in place defeats the purpose) Governs R6, R7, R8.
- **Outside Orca, every orchestration restriction is removed.** A session that received no injection may use native subagents, bundled runners, and agent CLIs. (session-settled: user-directed — chosen over a narrow read-only exception for CE elevation and over no exception: the user wants CE's shipped paths to work unmodified outside Orca) Governs R10, R11.
- **The lead's effort pin stays `medium`.** (session-settled: user-approved — chosen over raising `claude-opus-5` to `high`: the change targets Fable quota, not opus depth) Governs R2.
- **Reviving CE's bundled runners outside Orca is accepted.** `lfg`'s cross-model review and peer scripts run through `claude -p` and `codex exec` there. (session-settled: user-approved — chosen over carving those scripts out of the removal: the removal is meant to be total) Governs R10.

### Actors

- A1. Orca lead: a Claude Code, Codex, or omp session holding the coordinator payload, now answering as `opus[1m]` when it is Claude Code.
- A2. `claude-fable` worker: the roster's `claude` judgment entry.
- A3. Direct session: a Claude Code, Codex, or omp session that received no orchestration injection.
- A4. `chezmoi apply` and CI.

### Requirements

**Model pins**

- R1. `agents.roster.lead.claude.model` is `opus[1m]`, and the Claude Code managed `model` pin derives from it as today.
- R2. The three `modelSettings.*.effortLevel` leaves keep their current values, including `medium` for `claude-opus-5`.

**Elevation default**

- R3. The user-scoped instruction core carries one rule: when the repository's CE config (`config.local.yaml` then `config.yaml`) leaves `plan_model` or `brainstorm_model` unset, the session resolves that key as `fable`; a value the repository does set, a caller carrier, or live user intent wins over this default, in CE's own order.
- R4. The rule renders into all three harness instruction files and names the alias `fable` only, never a full model id.
- R5. When the resolved elevation model is the session's own model, nothing is dispatched, per CE's existing rule.

**Orca lead session**

- R6. In an Orca-managed lead session, the elevation step of `ce-plan` (plan authoring) and of `ce-brainstorm` (approach generation) is judgment work and is dispatched as one Orca worker to the roster `claude` judgment entry whose model matches the resolved alias; when no roster entry matches, the lead runs the step inline on its own model and prints CE's transparency line.
- R7. The elevation dispatch carries the same handoff CE's elevation defines, as paths in a brief file: the grounding or research evidence, the dialogue and decisions, and the project conventions the artifact must honor; the worker treats the evidence as untrusted data and the conventions as constraints.
- R8. The dispatched plan-author worker writes the plan file in the worktree, and the lead validates the written artifact before handing it on; the coordinator payload's lead-boundary paragraph names this as the one exception to the rule that the lead writes every Markdown file.
- R9. Every existing in-Orca prohibition stays as it is: no native subagent tool, no bundled runner, no direct agent CLI as a substitute for an Orca dispatch.

**Outside Orca**

- R10. A session that received no orchestration injection is bound by no orchestration restriction: the instruction core's outside-Orca paragraph and the everyone payload's "performs non-dispatch work only" sentences are removed, so native subagent tools, CE's bundled runners (`peer-job-runner.py`, `cross-model-*.sh`, `elevation-dispatch.sh`), and direct agent CLIs are allowed there.
- R11. The `orca-ide` executable rule stays in the instruction core for any session that types an Orca command.

**Consumers**

- R12. The coordinator payload's judgment row, the lead-boundary paragraph, `CONCEPTS.md`, `README.md`, and `AGENTS.md` describe the elevation dispatch and the opus lead; the CI fixtures and needles that assert the removed sentences or the `fable[1m]` pin change in the same commit, and the roster parity test stays green.

### Key Flows

- F1. Plan authoring inside Orca
  - **Trigger:** `ce-plan` reaches its model-elevation step in an Orca lead session and the repository's CE config leaves `plan_model` unset.
  - **Actors:** A1, A2.
  - **Steps:** the lead resolves the alias as `fable` per R3; matches it to the `claude-fable` entry; writes the brief file with the evidence, decisions, and conventions paths; dispatches one worker; the worker authors the plan file and reports done; the lead reads and validates the file.
  - **Outcome:** a plan authored by Fable, validated by an opus lead.
  - **Covers R3, R6, R7, R8.**
- F2. Plan authoring outside Orca
  - **Trigger:** the same step in a direct Claude Code session.
  - **Actors:** A3.
  - **Steps:** the session resolves `fable` per R3 and runs CE's own adapter order unchanged: native subagent with a model override, then the Claude CLI worker, then inline; it prints CE's transparency line.
  - **Outcome:** the plan is authored by Fable through CE's shipped path.
  - **Covers R3, R10.**
- F3. Repository override
  - **Trigger:** a repository sets `plan_model` or `brainstorm_model` in its CE config.
  - **Actors:** A1 or A3.
  - **Steps:** CE's resolution reads the repository value; the instruction default never applies.
  - **Outcome:** the repository's choice governs, inside and outside Orca.
  - **Covers R3, R5.**

### Acceptance Examples

- AE1. **Covers R1.** Given the roster after this change, when `chezmoi apply` renders the Claude settings, then `model` is `opus[1m]` and no other file names the lead model by hand.
- AE2. **Covers R3, R6, R8.** Given an Orca lead session in a repository whose CE config sets neither key, when `ce-plan` reaches its elevation step, then the lead dispatches one `claude` `fable` worker and the plan file on disk is the worker's, validated by the lead.
- AE3. **Covers R5.** Given a repository whose CE config sets `plan_model: opus` and an opus lead, when `ce-plan` reaches its elevation step, then no worker is dispatched and the lead authors inline.
- AE4. **Covers R3, R10.** Given a direct Claude Code session with neither key set, when `ce-brainstorm` reaches approach generation, then the session elevates to Fable through CE's native subagent adapter and no instruction rule reports a violation.
- AE5. **Covers R3.** Given a repository whose `config.local.yaml` sets `brainstorm_model: sonnet`, when `ce-brainstorm` reaches approach generation, then Sonnet is the elevated model and the instruction default is not consulted.
- AE6. **Covers R10.** Given an `lfg` run in a direct session, when its cross-model review stage runs, then it runs through CE's bundled scripts and is neither reported as skipped nor routed through Orca.
- AE7. **Covers R9.** Given an Orca lead session, when any skill directs a subagent dispatch, then it still goes through Orca and never through the native subagent tool.

### Scope Boundaries

- Changes to the `compound-engineering` plugin itself, including an upstream user-level config layer.
- Every roster entry other than the lead pin; the `claude-fable` entry keeps `fable` at `high`.
- omp `modelRoles`, the Codex direct-session default, and the effort pins (R2 keeps them).
- Elevation for skills other than `ce-plan` and `ce-brainstorm`.

### Dependencies / Assumptions

- CE v3.26.3 resolves `plan_model` and `brainstorm_model` from live intent, a caller carrier, then the two repository config files, and has no user-level layer; a later CE version that adds one makes R3 redundant, not wrong.
- The Claude Code native subagent tool accepts a `fable` model override, so CE's first adapter serves the default outside Orca.
- The roster derivation and the `claude-fable` judgment entry from the roster plan are merged, so R1 is a one-line data change.

### Sources / Research

- `.chezmoidata/agents.yaml` lines 11-20 (lead pin and `claude-fable` entry), 299-315 (Claude settings derivation and effort leaves).
- `.chezmoitemplates/orchestration-coordinator.tmpl` line 45 (judgment row) and line 47 (the lead never takes judgment work back); the lead-boundary paragraph rendered into the coordinator payload.
- `.chezmoitemplates/agents-instructions.tmpl`: the Routing and mirrors section holds the outside-Orca paragraph and the `orca-ide` rule.
- `.chezmoitemplates/orchestration-everyone.tmpl`: the "performs non-dispatch work only" sentences.
- `CONCEPTS.md` lines 65-69 (Model roster, Judgment work).
- Compound Engineering v3.26.3: `skills/ce-brainstorm/references/reasoning-elevation.md` lines 13-28 (activation precedence and adapter order), byte-identical to the `ce-plan` copy; `skills/ce-plan/SKILL.md` line 56; `.compound-engineering/config.example.yaml` lines 74-75; `skills/lfg/references/stage-routing.md` line 37.
- Prior plan: `docs/plans/2026-09-16-2329-feat-orca-lead-dispatch-only-model-roster-plan.md` (R1, R7, R10 and the `fable[1m]` decision this plan reverses).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The lead pin is a one-line roster edit; every consumer follows by derivation.** `agents.roster.lead.claude.model` becomes `opus[1m]`, and the Claude settings reconciler already merges that leaf into `model`, so only the reconcile test's literal expectation and the two prose files change by hand. Governs R1, R12.
- KTD2. **The elevation-default rule is one paragraph in the instruction core, and its alias is rendered from the roster.** The paragraph lives in the Routing and mirrors section of `.chezmoitemplates/agents-instructions.tmpl`, and the alias comes from `agent-roster-lookup.tmpl` over the `claude` judgment entry through `.ctx`, so the instruction core never hand-writes a model id and a roster change to the judgment model moves the default with it. (session-settled: user-directed — chosen over an overlay of CE's elevation reference and over rendering `config.local.yaml` into garden projects: the instruction core is already rendered into all three harness files and CE stays untouched) Governs R3, R4.
- KTD3. **The elevation dispatch is a fourth kind of judgment work in the coordinator payload, with a single-worker shape and an inline degrade path.** The judgment row of `orchestration-coordinator.tmpl` gains the plan-authoring and approach-generation elevation steps; a paragraph after the routing table states that this work goes to one worker at the `claude` judgment entry matching the resolved alias, that it is the one judgment work the lead performs in place when no entry matches, and that a failed or unavailable elevation dispatch degrades inline on the lead's model with CE's transparency line instead of taking the row's replacement or re-dispatch columns, because CE's own recovery rule never substitutes a different model; the lead-boundary paragraph names the worker-written plan file as its one Markdown exception. The two-reviewer shape stays for reviews only. (session-settled: user-directed — chosen over a worker that returns the body for the lead to write and over the lead authoring on opus: a body handoff doubles tokens and risks re-narration) Governs R5, R6, R7, R8.
- KTD4. **Removal outside Orca is sentence deletion plus one scoping edit.** The instruction core loses its outside-Orca paragraph and the sentence "A session that has not received these instructions performs non-dispatch work only.", and its Orca-owns-dispatch paragraph is scoped to a session that received orchestration injection, because its "Before launching ANY subagent" wording would otherwise still bind a direct session and defeat R10; the everyone payload loses the "Absence of this text never waives the contract" paragraph and the trailing "Other harnesses and sessions holding only the pointer ... perform non-dispatch work only." sentence. Every prohibition inside the two payloads and the `orca-ide` rule keep their bytes, so their needles still match. (session-settled: user-directed — chosen over a narrow read-only exception: the removal is meant to be total) Governs R9, R10, R11.
- KTD5. **Needles change with the text in the same commit.** `.ci/test-agent-instructions.sh` carries the removed sentences as needles today; each unit that deletes or adds a sentence edits the matching needle block in the same commit, and no fixture file under `.ci/fixtures/agent-instructions/` is touched because none holds the changed paragraphs. Governs R12.

### Assumptions

- `agents-instructions.tmpl` receives the full chezmoi context as `.ctx`, so `.ctx.agents.roster` resolves inside it exactly as `.ctx.chezmoi.os` does today; if the wrapper passes a narrower dict, U2 widens the wrapper rather than hand-writing the alias.
- CE's elevation matches an alias against the harness's model names, so `fable` on the instruction core and `fable` on the roster judgment entry name the same model.
- The lfg run that implements this plan is itself an Orca lead session, so the coordinator payload it reads is the pre-change one until the plugin reinstalls; that is expected and changes nothing about the units.

### Sequencing

U1 first (roster pin, prose, reconcile test), then U2, U3, and U4 in any order, each as its own commit; U4 depends on nothing in U2 or U3 but reads the same needle file, so the three land serially to avoid needle-block conflicts.

---

## Implementation Units

### U1. Move the lead pin to opus[1m]

- **Goal:** the roster, the rendered Claude settings, the reconcile test, and the two prose files agree on `opus[1m]`.
- **Requirements:** R1, R2, R12 (KTD1). Covers AE1.
- **Dependencies:** none.
- **Files:** `.chezmoidata/agents.yaml` (line 14), `.ci/test-claude-settings-reconcile.sh` (lines 56-57), `README.md` (line 299), `AGENTS.md` (line 73).
- **Approach:**
  1. Change `agents.roster.lead.claude.model` to `opus[1m]` and leave the three `modelSettings.*.effortLevel` leaves untouched.
  2. Change the reconcile test's literal expectation for the roster lead to `opus[1m]`.
  3. In `README.md` and `AGENTS.md`, replace "Claude lead on `fable[1m]`" and "a Claude lead pinned to `fable[1m]`" with the opus pin, and add one clause that Fable is reached through CE model elevation.
- **Patterns to follow:** the derivation comment in `.chezmoidata/agents.yaml` lines 299-303 and the roster read in `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` line 7.
- **Test scenarios:**
  - Covers AE1. The rendered Claude settings pin `model` to `opus[1m]` and keep `modelSettings.claude-opus-5.effortLevel` at `medium`.
  - The roster parity test still finds every worker model id named in `README.md` and `AGENTS.md` inside the roster.
- **Verification:** `bash .ci/test-claude-settings-reconcile.sh` and `bash .ci/test-agent-roster.sh` pass; `grep -rn 'fable\[1m\]' --exclude-dir=docs .` is empty.

### U2. Add the elevation default and drop the outside-Orca restrictions in the instruction core

- **Goal:** the instruction core states the Fable elevation default with a roster-rendered alias and no longer restricts a session outside Orca.
- **Requirements:** R3, R4, R10, R11, R12 (KTD2, KTD4, KTD5). Covers AE4, AE5, AE6.
- **Dependencies:** U1.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl` (Routing and mirrors, lines 23-35), `.ci/test-agent-instructions.sh` (needles at lines 419-424).
- **Approach:**
  1. Delete the paragraph at line 29 and the sentence "A session that has not received these instructions performs non-dispatch work only." from line 31; scope the Orca-owns-dispatch paragraph at line 27 to an injected session by opening it with "In an Orca-managed session, " and binding its "never a substitute" sentence to that session; keep the omp paragraph's remaining sentences and the `orca-ide` block byte-identical.
  2. Add one paragraph after the omp paragraph: for each of `plan_model` and `brainstorm_model` separately, when the repository's CE config (`config.local.yaml` then `config.yaml`) leaves that key unset, the session resolves it as the rendered alias and reports the default as its config source in CE's transparency line; a repository value, a caller carrier, or live user intent wins in CE's own order; when the resolved model is the session's own model nothing is dispatched; a session outside Orca then runs CE's adapters as shipped.
  3. Render the alias with `includeTemplate "agent-roster-lookup.tmpl"` over the `claude` judgment entry from `.ctx.agents.roster`, mirroring the lookup at `orchestration-coordinator.tmpl` line 23.
  4. Replace the two removed needles with needles for the new paragraph's opening sentence and its "wins in CE's own order" sentence, and update the three needles at lines 419-421 to the scoped wording of the Orca-owns-dispatch paragraph.
- **Patterns to follow:** the roster lookup and `fromJson` unpack in `orchestration-coordinator.tmpl` lines 23-24; the needle blocks in `.ci/test-agent-instructions.sh`.
- **Test scenarios:**
  - Covers AE4, AE5. The rendered `~/.claude/CLAUDE.md`, Codex `AGENTS.md`, and omp `AGENTS.md` each contain the elevation-default paragraph naming the alias `fable` and the repository-wins sentence.
  - Covers AE6. None of the three rendered files contains "perform non-dispatch work only" or "never reach for a native subagent tool".
  - The rendered files contain the scoped "In an Orca-managed session," dispatch paragraph and, on Linux, the `orca-ide` sentence.
  - A stub roster whose `claude` judgment model is `stub-judge` renders the paragraph with `stub-judge`; the stub replaces `agents.roster.workers` wholesale, so it carries a full `claude` judgment entry rather than a partial override.
- **Verification:** `bash .ci/test-agent-instructions.sh` passes on both OS branches.

### U3. Drop the outside-Orca sentences from the everyone payload

- **Goal:** the everyone payload binds only sessions that received it.
- **Requirements:** R9, R10, R12 (KTD4, KTD5).
- **Dependencies:** U1.
- **Files:** `.chezmoitemplates/orchestration-everyone.tmpl` (lines 36 and 38), `.ci/test-agent-instructions.sh` (everyone needles near lines 516-519).
- **Approach:**
  1. Delete the paragraph at line 36 in full and, from line 38, the final sentence beginning "Other harnesses and sessions holding only the pointer".
  2. Remove the two matching needles; leave every other everyone needle and the coordinator needles unchanged.
- **Patterns to follow:** the surrounding paragraphs' voice; the everyone needle block.
- **Test scenarios:**
  - The rendered everyone payload contains no "non-dispatch work only" and no "Absence of this text never waives the contract".
  - Covers AE7. The rendered everyone payload still contains the native-subagent prohibition and the bundled-runner prohibition.
  - Both plugin `plugin.json` versions change, because the payload body is a digest input.
- **Verification:** `bash .ci/test-agent-instructions.sh`, `bash .ci/test-orchestration-hook.sh`, and `bash .ci/test-claude-codex-plugin-reconcile.sh` pass.

### U4. Route the elevation step through the coordinator payload

- **Goal:** the coordinator payload names the elevation step as judgment work with a single-worker shape and the lead-boundary exception.
- **Requirements:** R5, R6, R7, R8, R12 (KTD3, KTD5). Covers AE2, AE3.
- **Dependencies:** U1.
- **Files:** `.chezmoitemplates/orchestration-coordinator.tmpl` (line 36 lead boundary; line 45 judgment row; a new paragraph after line 47), `.ci/test-agent-instructions.sh` (coordinator needles), `AGENTS.md` (line 73 region), `CONCEPTS.md` (Judgment work entry, lines 68-69; the working-tree edit already made to it lands in this unit's commit).
- **Approach:**
  1. Extend the judgment row's work-shape cell with "and the model-elevation step of `ce-plan` plan authoring and `ce-brainstorm` approach generation".
  2. Add one paragraph after the agent-unavailable paragraph that opens by naming itself the one exception to that paragraph's "never takes the row's work back" sentence: the elevation step dispatches one worker to the `claude` judgment entry whose model matches the resolved alias (rendered as `{{ $judgeClaude.model }}`), the brief file carries the evidence, dialogue, and conventions paths per R7, the worker writes the plan file and the lead validates it, an alias with no matching entry runs inline on the lead's model with CE's transparency line, and a failed or unavailable elevation dispatch degrades the same way and never takes the row's replacement or re-dispatch columns (KTD3). Keep the word "rung" off any line that renders the alias, because both needle and parity tests fail a coordinator line that carries `fable` beside "rung".
  3. Append to the lead-boundary paragraph one sentence naming the worker-written plan file as the one Markdown file the lead does not write.
  4. Add coordinator needles for the new row text, the exception sentence, and the inline-degrade sentence; add one sentence to `AGENTS.md` line 73's paragraph describing the elevation dispatch.
- **Patterns to follow:** the roster lookups at lines 23-24 and the judgment row at line 45; `CONCEPTS.md` Judgment work entry.
- **Test scenarios:**
  - Covers AE2. The rendered coordinator payload names the elevation step in the judgment row and states the single-worker dispatch with the alias `fable`.
  - Covers AE3. The rendered coordinator payload states that a resolved model equal to the lead's own model dispatches nothing.
  - The rendered coordinator payload states that a failed or unavailable elevation dispatch degrades inline and does not advance to the row's omp replacement.
  - The rendered coordinator payload's routing table still has four rows and the R12 brief table seven rows.
  - The roster parity test's rendered id set still equals the roster set.
- **Verification:** `bash .ci/test-agent-instructions.sh` and `bash .ci/test-agent-roster.sh` pass; `grep -c "elevation" <rendered coordinator payload>` is at least 2.

---

## Verification Contract

| Check | Command | Applies to | Done signal |
|---|---|---|---|
| Claude settings derivation | `bash .ci/test-claude-settings-reconcile.sh` | U1 | exit 0; `model` is `opus[1m]` |
| Roster parity and prose scan | `bash .ci/test-agent-roster.sh` | U1, U4 | exit 0 |
| Instruction files and payload needles | `bash .ci/test-agent-instructions.sh` | U2, U3, U4 | exit 0 on both OS branches |
| Hook and plugin reconcile | `bash .ci/test-orchestration-hook.sh`, `bash .ci/test-claude-codex-plugin-reconcile.sh` | U3, U4 | exit 0 |
| Apply convergence | `chezmoi apply --dry-run --verbose` then `chezmoi apply` twice | all | second apply changes zero targets |
| CI | GitHub Actions on the PR | all | green |

---

## Definition of Done

- Every R1–R12 is implemented and each AE is exercised by a test scenario (AE2–AE7 are prompt rules verified by rendered text).
- No file outside `docs/` names `fable[1m]`; no rendered instruction file or payload contains "non-dispatch work only".
- The instruction core's elevation alias and the coordinator payload's alias both render from the roster judgment entry.
- All listed test scripts pass; CI is green; a second `chezmoi apply` is a no-op.
- Per unit: U1 reconcile and parity tests pass; U2 needle test passes on both OS branches; U3 hook and plugin reconcile tests pass; U4 needle and parity tests pass.
