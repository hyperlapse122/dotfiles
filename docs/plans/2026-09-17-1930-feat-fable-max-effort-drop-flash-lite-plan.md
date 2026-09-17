---
title: Fable Max Effort and Flash-Lite Removal - Plan
type: feat
date: 2026-09-17
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fable Max Effort and Flash-Lite Removal - Plan

## Goal Capsule

- **Objective:** Every Fable judgment launch an Orca lead makes (code review, peer review, brainstorm, plan, doc review, `ce-pov`, `ce-ideate`) runs at `max` effort, Compound Engineering plan and brainstorm elevation runs Fable at `max` outside Orca on both of its adapters, and every initial mechanical dispatch starts on an omp seat that can finish a scout read; substantive failures follow R9's fallback chain.
- **Means:** Move both Fable effort levers to `max` and hold them equal (KTD1), overlay the Compound Engineering CLI elevation adapter so it passes `max` (KTD7), retire `omp-flash-lite` by giving `omp-flash` both omp shapes while every consumer keeps its shape lookup (KTD2), and make the coordinator carry the Claude judgment pair into each launch (KTD4).
- **Authority:** GitHub issue #535 and the three session-settled decisions recorded under Key Decisions.
- **Execution profile:** five Implementation Units in one branch and one PR; U1, U2, U3, and U5 are dispatched to Orca workers, U4 is the lead's Markdown unit; CI on the PR head is the acceptance gate.
- **Stop conditions:** a chezmoi render that fails on the changed roster is a stop until the data and the template agree; a `launch.effective` that does not report the requested pair is not a stop, it is recorded as degraded per R3.
- **Tail ownership:** the implementation tail owns verification with the `.ci/test-*.sh` scripts against disposable fixtures, review fixes, commit, push, PR, and the CI watch; no live `chezmoi apply` against the real home.

---

## Product Contract

### Summary

The `claude-fable` roster worker moves from `high` to `max` effort, and the Claude Code `modelSettings` effort leaf for the same model moves from `medium` to `max`, so Fable runs at maximum effort whether Orca dispatches it with an explicit effort or Compound Engineering's native adapter runs it at the harness default. The coordinator payload renders the Claude judgment seat with its effort, names the launch flags for the elevation worker, and requires the lead to verify the launch receipt the same way it already does for Codex. The `omp-flash-lite` entry is deleted, `omp-flash` takes the `mechanical` shape beside `implementation`, and the mechanical routing row, the omp seat-selection sentence, and omp's `tiny`, `skim`, and `smol` roles all resolve to `google-antigravity/gemini-3.8-flash`. A managed overlay makes Compound Engineering's Claude CLI elevation adapter pass `max` instead of its pinned `high`. Four CI tests and two prose files that pin the retired values change in the same PR.

### Problem Frame

The roster plan (`docs/plans/2026-09-16-2329-feat-orca-lead-dispatch-only-model-roster-plan.md`) placed Fable as the `claude` judgment entry at `high` effort, and the elevation plan (`docs/plans/2026-09-17-1130-feat-opus-lead-fable-elevation-default-plan.md`) routed plan authoring and brainstorm approach generation to that entry. Neither carried the entry's effort into a launch: the coordinator's judgment row renders the Claude model without an effort, the elevation paragraph names no effort, and outside Orca the native adapter runs at `modelSettings.claude-fable-5-1.effortLevel`, which is `medium`, while the Claude CLI adapter (`skills/ce-plan/scripts/elevation-dispatch.sh` and its `ce-brainstorm` twin in the pinned plugin archive) hard-codes `--effort high`. Judgment work therefore runs below maximum on every path.

The same roster plan split omp by shape, with `google-antigravity/gemini-3.5-flash-lite` as the only `mechanical` entry. That seat fails even scout reads, so the cheapest row of the routing table is the one row that cannot complete its work.

### Key Decisions

- **`claude-fable` runs at `max` effort.** (session-settled: user-directed — chosen over keeping `effort: high`: judgment work currently runs below maximum effort) Governs R1, R3.
- **`omp-flash-lite` is deleted and `omp-flash` takes the `mechanical` shape, so omp's `tiny`, `skim`, and `smol` roles and the coordinator mechanical row resolve to `omp-flash`.** (session-settled: user-directed — chosen over keeping flash-lite as the mechanical model: flash-lite fails even scout reads) Governs R5, R6, R7, R8.
- **Compound Engineering elevation dispatches Fable at `max`, not at the settings default.** (session-settled: user-directed — chosen over relying on the settings default effort: acceptance criterion 1 of issue #535) Governs R3, R4, R11, R20.

### Requirements

**Fable effort**

- R1. The `claude-fable` worker in `.chezmoidata/agents.yaml` declares `effort: max`.
- R2. `agents.claude.settings` declares `modelSettings.claude-fable-5-1.effortLevel: max`; the `claude-opus-5` and `claude-sonnet-5` leaves keep `medium` and `high`.
- R3. In an Orca lead session, every `claude` judgment launch, a reviewer in the judgment row and the elevation worker alike, selects the roster judgment entry's model and effort explicitly; the lead compares `launch.requested` with `launch.effective`, claims the pair only when the effective fields report it, and otherwise records the pass as degraded with the effective values or their absence.
- R4. Outside Orca, Compound Engineering's native Claude Code subagent adapter runs Fable at the `modelSettings` effort R2 sets, its Claude CLI adapter runs Fable at the effort R20 sets, and the user-scoped instruction core names both routes.
- R20. The Claude CLI elevation adapter of both `ce-plan` and `ce-brainstorm`, in every managed copy of the pinned Compound Engineering archive, passes `--effort max`.

**omp roster**

- R5. The `omp-flash-lite` worker is removed, and no roster entry names `google-antigravity/gemini-3.5-flash-lite`.
- R6. The `omp-flash` worker declares `shapes: [implementation, mechanical]` and keeps `google-antigravity/gemini-3.8-flash` at `high`.
- R7. The rendered omp settings declare `enabledModels` as the single model `google-antigravity/gemini-3.8-flash`, and every model-valued role, `tiny`, `skim`, and `smol` included, is `google-antigravity/gemini-3.8-flash:high`; the `@worker` and `@fable` aliases are unchanged.
- R8. The rendered coordinator's mechanical row names `omp` `google-antigravity/gemini-3.8-flash` high as its first recipient, and its omp seat-selection sentence names that one seat for every omp launch.

**Coordinator routing**

- R9. The mechanical row's substantive-failure column is `codex` at the fallback pair, then `claude` at the `sonnet` rung, because the omp implementation seat it named before is now the same seat as the first recipient; the agent-unavailable column is unchanged.
- R10. The judgment row renders the `claude` seat as model and effort, in the same shape as its `codex` seat.
- R11. The elevation paragraph states that the single elevation worker is launched with the judgment entry's model and effort, and the launch-receipt rule of R3 applies to it.
- R12. The omp seat-selection sentence renders one seat when the mechanical and implementation lookups return the same model and effort, and the two-seat form otherwise; the sentence fragments the needle test pins keep their bytes.

**Rendered surfaces, tests, and prose**

- R13. The rendered coordinator's routing table has four rows and its brief-guidance table has five rows.
- R14. No roster entry, template, script, rendered output, test stub, or prose file outside `docs/` names `gemini-3.5-flash-lite` or `omp-flash-lite`; the only exceptions are CI assertions that name a retired value to prove its absence (the omp reconcile test's retired-model loop and the roster test's stale-prose guard); test stubs that need a distinct mechanical entry use ids and models that are visibly fake.
- R15. `.ci/test-agent-roster.sh`, `.ci/test-agent-instructions.sh`, `.ci/test-omp-settings-reconcile.sh`, and `.ci/test-claude-settings-reconcile.sh` assert the new values, and each keeps proving what it proves today: a roster edit to the mechanical seat reaches the coordinator, a distinct mechanical entry still drives omp's `tiny` role, the catalog probe still warns on an absent selector and on an unsupported thinking level, and the two Claude effort leaves that did not move survive the merge.
- R16. The rendered Claude judgment pair is asserted from a roster render, never from a literal, on the committed roster and on a stub whose judgment effort differs from the committed one.
- R17. `README.md` and `AGENTS.md` describe five workers, Fable at `max` effort, and omp implementation and mechanical work on one `gemini-3.8-flash` seat; the stale-count guard in the roster test rejects "six worker" as it rejects "seven worker".
- R18. A comment the change makes false is corrected, a comment that records a constraint stays, and no comment that restates the data is added.
- R19. The fixture-backed instruction paragraphs are byte-identical before and after, the harness renders keep their parity, and every CI test passes on the pinned chezmoi binary against disposable fixtures.

### Scope Boundaries

- The `claude-opus`, `claude-sonnet`, and `codex-luna` roster entries, and the lead pins.
- The omp `plan: @fable` and `advisor`/`commit: @worker` aliases.
- The Compound Engineering plugin upstream, every plugin file other than the two elevation adapters U5 overlays, and any alias-to-model-id mapping inside this repository.
- The outside-Orca cross-model review pass keeps its plugin defaults; this plan changes the Fable effort only on the Orca judgment row and the elevation paths.
- `CONCEPTS.md`: its Model roster, Judgment work, and Mechanical work entries name no model id or effort and stay as they are.
- Historical files under `docs/` that name `gemini-3.5-flash-lite`, including `docs/decommission/omp.md`.

### Sources / Research

- Issue #535: title, two findings, proposal, scope list, and acceptance criteria 1 through 5 (five unlabeled checkboxes, counted in order).
- The pinned plugin archive's `skills/ce-plan/scripts/elevation-dispatch.sh` line 34 (`EFFORT="high"`), byte-identical to the `ce-brainstorm` copy; `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl` and `.ci/test-compound-engineering-overlays.sh` (the existing overlay installer and its test).
- `.chezmoidata/agents.yaml` lines 19-29 (`claude-fable`), 61-79 (`omp-flash`, `omp-flash-lite`), 292-308 (Claude effort leaves and their comment), 374-380 (omp derivation comment).
- `.chezmoitemplates/agent-roster-lookup.tmpl` (last match wins; fails render when nothing matches) and `.chezmoitemplates/agent-roster-validate.tmpl` line 34 (valid shapes; no rule that a mechanical entry be distinct; effort values unrestricted).
- `.chezmoitemplates/orchestration-coordinator.tmpl` lines 21-27 (lookups), 42 (mechanical row), 45 (judgment row), 49 (elevation paragraph), 51 (omp seat-selection sentence), 59-61 (brief-guidance table).
- `.chezmoitemplates/orchestration-everyone.tmpl` line 38 (the Codex launch rule that R3 mirrors).
- `.chezmoitemplates/agents-instructions.tmpl` lines 31-33 (elevation-default paragraph).
- `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` lines 1-8 (header comment), 9-33 (derivation), 175-192 (roster catalog probe).
- `.ci/test-agent-roster.sh` lines 60, 274-294, 330-336, 356-374, 414-418; `.ci/test-agent-instructions.sh` lines 428-429, 617-635, 668-682; `.ci/test-omp-settings-reconcile.sh` lines 42-79, 130-154, 275-305, 365-389, 621-641; `.ci/test-claude-settings-reconcile.sh` lines 53-72.
- `README.md` line 299 and `AGENTS.md` line 74.
- Claude Code 2.1.274 accepts `max` as an effort value in its settings schema, read from the pinned binary; the Claude settings validator does not restrict effort values.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Both Fable effort levers move to `max` together, and the Claude settings reconcile test holds them equal.** The roster effort is what an Orca launch forwards, and the `modelSettings.claude-fable-5-1.effortLevel` leaf is what Compound Engineering's native subagent adapter runs at outside Orca, because that adapter has no per-dispatch effort knob; moving one lever leaves one path below maximum. The CLI adapter ignores both levers and is handled by KTD7. The leaf stays declared by hand, because the roster names the alias `fable` and no mapping from alias to the `claude-fable-5-1` settings id exists in this repository, so `.ci/test-claude-settings-reconcile.sh` gains one assertion that the declared leaf equals the roster `claude` judgment entry's effort, rendered through `agent-roster-lookup.tmpl`, and the comment above the leaves records why that leaf mirrors the roster. Implements the first and third Key Decisions (R1, R2, R4, R15).
- KTD2. **`omp-flash` carries both omp shapes, and every consumer keeps its shape lookup.** The coordinator's `$mechanical` and `$ompImpl` lookups and the omp reconciler's two selectors stay as they are, so a future distinct mechanical entry re-lands with a roster edit alone, and the validator needs no new rule because it never required a distinct mechanical entry. The test stubs that prove a distinct mechanical entry still drives its consumers use visibly fake ids and models. (session-settled: user-directed — chosen over keeping flash-lite as the mechanical model: flash-lite fails even scout reads) Governs R5, R6, R7, R8, R14, R15.
- KTD3. **The mechanical row's substantive-failure column becomes `codex` at the fallback pair, then `claude` at the `sonnet` rung.** The row previously retried a substantive failure on the omp implementation seat; with one omp seat that retry is the same seat with the same brief, which the sizing paragraph forbids. The mechanical row's own agent-unavailable cell already reads the codex fallback pair then `claude` at the `sonnet` rung, so the substantive-failure cell takes that same text and the agent-unavailable cell stays byte-identical. Governs R9.
- KTD4. **The Claude judgment pair reaches every launch through the coordinator payload.** The judgment row renders `{{ $judgeClaude.model }}` followed by `{{ $judgeClaude.effort }}`; one new sentence after the elevation paragraph states that every `claude` judgment launch, reviewer or elevation worker, selects `--model` and `--effort` from that entry and that the lead compares `launch.requested` with `launch.effective` and records a mismatch as degraded, mirroring the Codex rule in the everyone payload; the elevation paragraph gains a clause naming the same pair for its single worker. The instruction core's elevation-default paragraph gains one sentence: inside Orca the dispatch carries the entry's effort, and outside Orca the adapter runs at the Claude Code `modelSettings` effort for that model, which this repository holds at the same value. The everyone payload is untouched, because a Claude launch is a lead action and the everyone body is the Codex plugin's digest input. Governs R3, R4, R10, R11, R16.
- KTD5. **The omp seat-selection sentence branches on seat equality inside the template.** When the mechanical and implementation lookups return the same model and effort, the sentence names that one seat for every omp launch; otherwise it renders the two-seat form it renders today. The fragments the needle test pins, the `worker-start --model` sentence opening and "confirms the model from the terminal, and dispatches with `worker-start --terminal <handle>`.", stay byte-identical in both branches. Governs R8, R12.
- KTD6. **Every retired literal in a test becomes a roster render or a fake stub value.** The seat-selection assertion in `.ci/test-agent-roster.sh` renders the omp mechanical seat through `agent-roster-lookup.tmpl` instead of grepping the literal model id; the Claude judgment pair is asserted with the same seat-pair pattern the Codex seats already use; the omp reconcile test's catalog fixtures and swapped roster name the single committed model and one fake mechanical model. Negative assertions that prove a retired value is absent keep naming it, per R14. Governs R14, R15, R16.
- KTD7. **A checksum-guarded overlay replaces the two CLI elevation adapters.** The existing overlay installer gains a second file class: a whole-file replacement of an archive-owned file, installed only when the archive copy's SHA-256 equals the recorded upstream v3.26.3 digest; any other digest leaves the archive file untouched and prints a warning naming the file and the observed digest, so a plugin bump never receives a stale fork and never fails the apply. The overlay source is the upstream script with the effort line changed to `max` and no other difference, and its test proves that. The installer's header comment changes from "never changes archive-owned files" to name this guarded exception. A whole-file copy is chosen over an in-place line edit because the installer already owns whole-file copies with byte-compare convergence. Implements the third Key Decision (R4, R20).

### Assumptions

- Orca's `worker-start --effort max` is accepted for a Claude launch and `launch.effective` reports it; the version-matched Orca guide owns the spelling, and a launch whose receipt cannot report the pair is recorded as degraded per R3 rather than treated as a plan defect.
- Compound Engineering's native adapter, a Claude Code subagent with `model: fable`, runs at `modelSettings.claude-fable-5-1.effortLevel`; this is read from the adapter reference and the settings schema, not observed in a run, and no receipt reports the effort on that route.
- The Claude CLI accepts `--effort max` for `fable`, because its effort enum lists `max`.
- `google-antigravity/gemini-3.8-flash` serves `high` thinking on the authoring host, unchanged from today, so the catalog probe stays silent there.
- The Claude and Codex plugin manifests re-version from the changed payload digest without an edit, as `.ci/test-agent-roster.sh` already proves for a roster change.

### Risks and Dependencies

- Every Fable review, brainstorm, plan, and doc review costs more time and quota at `max`; the issue accepts this.
- Mechanical scout reads move from the lite seat to `gemini-3.8-flash`; the cost rises, and the row gains a seat that completes the work.
- U1 alone leaves `.ci/test-agent-roster.sh` and `.ci/test-omp-settings-reconcile.sh` red until U2 and U3 land, so the five units ship in one PR and CI is judged at its head.
- The U5 overlay forks two upstream plugin files; a Compound Engineering version bump changes the digest, the guard skips the overlay with a warning, and CLI elevation falls back to `high` until the overlay is refreshed for the new version.
- An Orca `worker-start` that rejects `--effort max` for a Claude launch before the agent starts is a mechanical failure the coordinator would re-dispatch at the same row; the U3 launch-receipt check in the Verification Contract surfaces it before merge.

### Sequencing

U1 first, because every other unit renders from the roster it changes. U2, U3, and U5 follow in any order. U4 lands last, after the rendered values it describes exist.

---

## Implementation Units

### U1. Move the roster and settings effort levers and retire the lite entry

- **Goal:** the roster declares Fable at `max` and one omp entry with both shapes, the Claude settings declaration pins Fable at `max`, and the Claude reconcile test asserts both and holds them equal.
- **Requirements:** R1, R2, R5, R6, R15, R18 (KTD1, KTD2).
- **Dependencies:** none.
- **Files:** `.chezmoidata/agents.yaml` (lines 22, 65, 71-79, 292-296, 306), `.ci/test-claude-settings-reconcile.sh` (lines 66-72).
- **Approach:**
  1. Set `effort: max` on `claude-fable`; set `shapes: [implementation, mechanical]` on `omp-flash`; delete the `omp-flash-lite` entry with its brief.
  2. Set `modelSettings.claude-fable-5-1.effortLevel: max`; leave the opus and sonnet leaves.
  3. Extend the comment above the effort leaves with one clause: the `claude-fable-5-1` leaf mirrors the `claude` judgment entry's effort because the non-Orca elevation path reads the leaf, and the reconcile test holds the two equal.
  4. In the reconcile test, change the fable expectation to `max`, reword its comment, and add one assertion that renders the `claude` judgment entry's effort through `agent-roster-lookup.tmpl` with `execute-template`, the way line 55 renders the lead model, and compares it with the declared fable leaf.
- **Patterns to follow:** the lead-model render at `.ci/test-claude-settings-reconcile.sh` lines 53-59; the lookup call shape at `.chezmoitemplates/orchestration-coordinator.tmpl` line 23.
- **Test scenarios:**
  - The rendered Claude settings declaration carries `modelSettings.claude-fable-5-1.effortLevel` equal to `max`, `claude-opus-5` equal to `medium`, and `claude-sonnet-5` equal to `high`.
  - The declared fable leaf equals the roster `claude` judgment entry's rendered effort; a roster render with the judgment effort overridden to `high` makes that assertion fail, which proves the guard can fail.
  - The committed roster renders through the validator and prints five model ids, none of them `google-antigravity/gemini-3.5-flash-lite`.
- **Verification:** the Claude settings reconcile test passes; a roster validator render of the committed data succeeds with five ids.

### U2. Point the omp settings reconciler and its test at the single omp seat

- **Goal:** the rendered omp settings name one model in `enabledModels` and `gemini-3.8-flash:high` in every model-valued role, the reconciler's header comment is true again, and the test proves the same behaviors it proves today without the retired model.
- **Requirements:** R7, R14, R15, R18 (KTD2, KTD6).
- **Dependencies:** U1.
- **Files:** `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` (lines 1-8), `.ci/test-omp-settings-reconcile.sh` (lines 42-79, 130-154, 275-305, 365-389, 621-641).
- **Approach:**
  1. Reword the header comment: omp roster entries are selected by shape, an entry may carry both shapes, and the two selectors then name one seat; keep the sentence about merging in the template so the derived leaves pass the validator.
  2. In the test, drop the `gemini-3.5-flash-lite:high` needle, add `gemini-3.5-flash-lite` to the retired-model loop, set the `enabledModels` expectation to the single model, and set `skim`, `smol`, and `tiny` to `google-antigravity/gemini-3.8-flash:high`.
  3. Rebuild the catalog fixtures around one roster model: the full catalog lists `gemini-3.8-flash` with `high`; the partial catalog lists a fake `google-antigravity` selector so the provider is covered and the roster model is absent, and the warning assertion names `gemini-3.8-flash`; the thinking-gap catalog lists `gemini-3.8-flash` without `high`, and its warning assertion names `gemini-3.8-flash`.
  4. Replace the swapped roster's `omp-flash-lite` entry with a fake distinct mechanical entry, such as `omp-lite-stub` on `google-antigravity/gemini-9.8-lite-stub`, and assert `tiny` follows it while `default` follows the fake implementation model.
- **Patterns to follow:** the fake-id convention in `.ci/test-agent-roster.sh` line 366 (`gemini-9.9-stub`); the existing catalog fixture layout.
- **Test scenarios:**
  - The rendered reconciler declares `enabledModels` as exactly `["google-antigravity/gemini-3.8-flash"]` and every model-valued role as `google-antigravity/gemini-3.8-flash:high`, with `advisor`, `commit`, and `plan` unchanged.
  - The rendered reconciler contains none of `gemini-3.7-flash`, `gemini-3.1-flash-lite`, or `gemini-3.5-flash-lite`.
  - With the partial catalog, the run warns that the provider does not serve `gemini-3.8-flash`, still asserts `modelRoles`, and exits 0.
  - With the thinking-gap catalog, the run warns that `gemini-3.8-flash` does not offer `high`, still asserts `modelRoles`, and exits 0.
  - With the swapped roster, `modelRoles.default` follows the fake implementation model and `modelRoles.tiny` follows the fake mechanical model.
- **Verification:** the omp settings reconcile test passes; in this unit's files, `gemini-3.5-flash-lite` appears only in the retired-model loop, per R14.

### U3. Carry the Fable pair and the single omp seat through the payloads and their tests

- **Goal:** the coordinator payload renders the Claude judgment seat with its effort, states the Claude launch and receipt rule, routes the mechanical row's substantive failure past the single omp seat, and names one omp seat; the instruction core names the effort on both elevation paths; the two payload tests assert all of it from roster renders.
- **Requirements:** R3, R4, R8, R9, R10, R11, R12, R13, R14, R15, R16, R19 (KTD3, KTD4, KTD5, KTD6).
- **Dependencies:** U1.
- **Files:** `.chezmoitemplates/orchestration-coordinator.tmpl` (lines 42, 45, 49, 51), `.chezmoitemplates/agents-instructions.tmpl` (line 33), `.ci/test-agent-roster.sh` (lines 54-60, 274-294, 330-336, 356-374, 414-418), `.ci/test-agent-instructions.sh` (lines 617-635, 668-682).
- **Approach:**
  1. Mechanical row: replace the substantive-failure cell with the text of the same row's agent-unavailable cell (the codex fallback pair, then `claude` at the `sonnet` rung); keep the first-recipient and unavailable cells.
  2. Judgment row: render the `claude` seat as `{{ $judgeClaude.model }}` followed by `{{ $judgeClaude.effort }}`, keeping the single-worker-exception pointer on that line and the word "rung" off it.
  3. Elevation paragraph: after "goes to that entry", add a clause that the worker is launched with `--model {{ $judgeClaude.model }} --effort {{ $judgeClaude.effort }}`; keep the two sentences the needle test pins byte-identical.
  4. Add one sentence after the elevation paragraph: every `claude` judgment launch, a reviewer in the judgment row and the elevation worker alike, selects that pair; the lead compares `launch.requested` with `launch.effective`, claims the pair only when the effective fields report it, and otherwise records the pass as degraded with the effective values or their absence.
  5. omp seat-selection sentence: wrap the seat clause in a template conditional on model and effort equality between `$mechanical` and `$ompImpl`; the equal branch names the one seat for mechanical and implementation work alike, the other branch keeps today's text; both branches keep the pinned opening and closing fragments.
  6. Instruction core: after "nothing is dispatched.", add one sentence that an Orca-managed session launches the elevation entry at its roster effort `{{ $judgeClaude.effort }}`, and that outside Orca the native subagent adapter runs at the Claude Code `modelSettings` effort for that model and the CLI adapter at the effort this repository's overlay sets, both held at the same value; keep the two pinned needles intact.
  7. Roster test: change the two counts to five; replace the seat-selection literal grep with a render of the omp mechanical seat through `agent-roster-lookup.tmpl` and assert the seat-selection line names it; add a Claude judgment seat-pair anchor for `--model` and `--effort` built the way the Codex anchors are; in the two-seat Codex stub and the AE9 stub, drop the `omp-flash-lite` entry and give `omp-flash` both shapes; in the AE9 stub move `omp-flash` to `gemini-9.9-stub` and set `claude-fable` to effort `low`, then assert the stub model reaches the coordinator, `gemini-3.8-flash` does not survive, and the launch anchor renders `--effort low`; add a two-entry omp stub with a fake distinct mechanical entry and assert the mechanical row's first recipient and the seat-selection line name it; add `omp-flash-lite` and "six worker" to the stale-prose guard.
  8. Instructions test: drop `omp-flash-lite` from the stub roster and give its `omp-flash` both shapes; add Claude-only coordinator needles for the static parts of the new launch sentence and the elevation clause; add an instruction-core needle for the static part of the new effort sentence.
- **Patterns to follow:** the Codex launch rule at `.chezmoitemplates/orchestration-everyone.tmpl` line 38; the Codex seat-pair anchors at `.ci/test-agent-roster.sh` lines 296-354; the needle blocks at `.ci/test-agent-instructions.sh` lines 560-635; the roster-built needles at lines 637-650.
- **Test scenarios:**
  - The rendered coordinator's mechanical row names `omp` `google-antigravity/gemini-3.8-flash` high first, then `codex` `gpt-5.6-luna` max and `claude` `sonnet` on substantive failure, then the unchanged unavailable cell.
  - The rendered coordinator's judgment row names `claude` `fable` max and `codex` `gpt-5.6-luna` max over the same brief, and the fold-back check that greps "over the same brief" without the single-worker pointer still passes.
  - The rendered coordinator carries `--model fable --effort max` in the elevation clause and the launch sentence, and the launch sentence carries `launch.requested` and "records the pass as degraded".
  - The rendered coordinator's seat-selection line names `google-antigravity/gemini-3.8-flash` at `high` once, for mechanical and implementation work alike, and still carries the two pinned fragments.
  - The routing table has four rows and the brief-guidance table five; the rendered id set equals the roster id set in both directions; no `fable` appears on a line with "rung".
  - The AE9 stub renders `gemini-9.9-stub`, drops `gemini-3.8-flash`, and renders `--effort low` in the launch anchor.
  - The two-entry omp stub renders the fake mechanical model in the mechanical row and in the two-seat branch of the seat-selection line.
  - Each of the three harness renders carries the new instruction-core sentence, and the stub-judge roster still renders "the session resolves it as `stub-judge`".
  - The fixture-backed paragraphs still equal their fixtures and the three harness renders still match outside the harness paragraphs.
- **Verification:** the agent roster test and the agent instructions test pass on both OS branches; the orchestration hook test and the Claude and Codex plugin reconcile test pass, because the coordinator body is a digest input.

### U4. Update the committed prose

- **Goal:** `README.md` and `AGENTS.md` describe the roster as it now renders.
- **Requirements:** R17 (KTD1, KTD2, KTD7).
- **Dependencies:** U1, U3, U5.
- **Files:** `README.md` (line 299), `AGENTS.md` (lines 67 and 74).
- **Approach:**
  1. README: "six worker models" becomes "five worker models"; the omp clause becomes omp implementation and mechanical work on `google-antigravity/gemini-3.8-flash`; drop the flash-lite clause.
  2. AGENTS: "six worker entries" becomes "five worker entries"; `claude` on `fable` becomes "(max effort)"; the two omp clauses become one entry on `gemini-3.8-flash` (high effort) for implementation and mechanical work; state that `tiny`, `skim`, and `smol` map to the mechanical entry and every other model role to the implementation entry, which are today one entry; add to the elevation sentence that the worker is launched at the entry's effort and the lead verifies the launch receipt.
  3. AGENTS: where the omp archive paragraph says both copies receive the same ce-sweep references, add that they also receive the checksum-guarded CLI elevation adapter overlay (KTD7).
- **Patterns to follow:** the existing sentence rhythm of both paragraphs; the prose scan in `.ci/test-agent-roster.sh` lines 376-418.
- **Test scenarios:**
  - Test expectation: none -- prose only; the roster test's prose scan and stale-count guard cover it.
- **Verification:** the agent roster test passes, so every model id the two files name is a roster or lead model and neither file says "six worker", "seven worker", `omp-flash-lite`, or `flash-lite`.

### U5. Overlay the Compound Engineering CLI elevation adapters at `max`

- **Goal:** both managed archive copies of the pinned plugin run CLI elevation for `ce-plan` and `ce-brainstorm` with `--effort max`, and a plugin bump never receives a stale fork.
- **Requirements:** R4, R18, R20 (KTD7).
- **Dependencies:** none.
- **Files:** `dot_local/share/compound-engineering-overlays/skills/ce-plan/scripts/elevation-dispatch.sh`, `dot_local/share/compound-engineering-overlays/skills/ce-brainstorm/scripts/elevation-dispatch.sh`, `.chezmoiscripts/00-tools/run_after_compound-engineering-overlays.sh.tmpl`, `.ci/test-compound-engineering-overlays.sh`.
- **Approach:**
  1. Copy the pinned upstream `skills/ce-plan/scripts/elevation-dispatch.sh` into both overlay paths, keep its executable mode, and change only the effort assignment to `max` with its trailing comment updated to say this repository raises it.
  2. In the installer, add the two scripts as guarded replacements: each entry carries the recorded upstream SHA-256; before replacing, compare the archive file's digest with it and with the overlay's own digest; install when the archive matches upstream, skip silently when it already matches the overlay, and warn and skip otherwise.
  3. Keep the installer's existing symlink and directory-chain safety for the new entries, and preserve the executable bit on the installed copy.
  4. Rewrite the header comment's "never changes archive-owned files" sentence to name the guarded exception and why it exists.
  5. In the overlay test, assert the overlay differs from the pinned upstream only on the effort line, assert the installed copy carries `max` after apply, assert a mismatching upstream digest leaves the archive file byte-identical and prints the warning, and assert a second apply writes nothing.
- **Patterns to follow:** the existing ce-sweep overlay entries and their test cases in `.ci/test-compound-engineering-overlays.sh`.
- **Test scenarios:**
  - With an archive copy whose script matches the recorded upstream digest, apply installs the overlay, the installed script assigns `max`, and it stays executable.
  - With an archive copy whose script has a different digest, apply leaves it byte-identical, prints a warning naming the file and digest, and exits 0.
  - A second apply after a successful install makes no write.
  - The overlay and the upstream script differ on exactly one line, the effort assignment.
  - Both `compound-engineering` and `compound-engineering-omp` archive copies receive the overlay.
- **Verification:** the overlay test passes, and running the overlay script's argv construction offline shows `--effort max`.

---

## Verification Contract

Every check renders with the pinned chezmoi binary against disposable source and home fixtures the scripts create; none touches the real home.

| Check | Command | Applies to | Done signal |
|---|---|---|---|
| Claude settings derivation and effort parity | render `.chezmoiscripts/70-agents/run_after_config-claude-settings.sh.tmpl` with `chezmoi execute-template` into a scratch file the way `.github/workflows/ci.yml` does, then `bash .ci/test-claude-settings-reconcile.sh <rendered-script>` | U1 | exit 0; fable leaf is `max` and equals the roster judgment effort |
| omp settings derivation and catalog probe | render `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` the same way, then `bash .ci/test-omp-settings-reconcile.sh <rendered-script>` | U1, U2 | exit 0; one enabled model, every role on it |
| CLI elevation overlay | `.ci/test-compound-engineering-overlays.sh <repo-root>` | U5 | exit 0 |
| Roster parity, seat anchors, table counts, prose scan | `bash .ci/test-agent-roster.sh` | U1, U3, U4 | exit 0 |
| Instruction files and payload needles | `bash .ci/test-agent-instructions.sh` | U3 | exit 0 on both OS branches |
| Hook and plugin digests | `bash .ci/test-orchestration-hook.sh`, `bash .ci/test-claude-codex-plugin-reconcile.sh` | U3 | exit 0 |
| Retired literal sweep | search the repository outside `docs/` for `gemini-3.5-flash-lite` and `omp-flash-lite` | U1, U2, U3, U4 | the only matches are the negative assertions R14 allows |
| Orca Fable launch receipt | the lead starts one Orca `claude` worker with `--model fable --effort max` from the PR branch | U3 | `launch.effective` reports `fable` and `max`; the receipt is recorded in the PR body |
| CI | GitHub Actions on the PR | all | green |

---

## Definition of Done

- R1 through R20 are implemented, and each test scenario above is exercised by the named script.
- The rendered Claude settings, the rendered omp settings, and the rendered coordinator table show Fable at `max`, one omp model, and the new mechanical row, which satisfies acceptance criterion 5 of issue #535.
- Acceptance criterion 1 of issue #535 is evidenced on the Orca path by the recorded launch receipt, on the CLI elevation path by the overlay test, and on the native subagent path by the R2 settings leaf, which the PR body records as unobserved at run time.
- R14 holds: outside `docs/`, the retired names appear only in the negative assertions it allows.
- The fixture-backed instruction paragraphs are unchanged and all listed tests pass; CI is green on the PR head.
- The diff carries no abandoned-attempt code: no leftover stub entry, commented-out row, duplicate needle, or fixture kept only for a retired assertion.
