---
title: Judgment Roster Tiers - Plan
type: refactor
date: 2026-09-18
topic: judgment-roster-tiers
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Judgment Roster Tiers - Plan

## Goal Capsule

- **Objective:** An Orca coordinator dispatching judgment work (code review, document review, `ce-pov`, `ce-simplify-code`) reaches `omp` by default for the personas Compound Engineering (CE) itself declares mid-tier or cheapest-capable, and reaches `claude` `opus` only for the personas CE declares session-model tier, so the roster's judgment cost and quality profile matches CE's own persona-level declarations instead of funneling every judgment persona through one flat `claude` `fable` row.
- **Means:** Add four judgment rungs (`judgment-cheap`, `judgment-standard`, `judgment-deep`, `judgment-escalation`) to `agents.yaml`, carried by the two existing `omp` rows plus one new `claude-opus-judgment` row and the existing `claude-fable` row; extend the coordinator's judgment routing table from one row to three; add a validation guard requiring at least one `omp` judgment row; lower the `authoring` rung's effort from `max` to `medium` and keep its two parity mirrors in sync (KTD1-KTD5).
- **Product authority:** [hyperlapse122/dotfiles#560](https://github.com/hyperlapse122/dotfiles/issues/560), filed by the repository owner, which states the target roster rows, the persona-to-rung table, and the completion checklist as confirmed decisions rather than open questions (see Key Decisions).
- **Execution profile:** Implementation and verification by `ce-work`-style units; each unit lands as one commit; the repository's `.ci/test-agent-roster.sh`, `.ci/test-claude-settings-reconcile.sh`, and `.ci/test-compound-engineering-overlays.sh` are the local acceptance gate, and CI on the pull request head is the final gate.
- **Stop conditions:** A chezmoi render that fails at a unit boundary is a stop until the roster data and its consumers agree; a red CI on the pull request head is a stop until fixed. No data migration, external API, or user-facing runtime surface is touched, so no other stop condition applies.
- **Who finishes and ships:** The implementing agent (`ce-work`) owns implementation, verification, review-fix application, commit, push, pull request, and the CI watch through to merge, under the invoking `/lfg` run's unattended contract.

---

## Product Contract

### Summary

The roster sends every `judgment`-shaped dispatch through one flat `claude` `fable` row while `mechanical` and `implementation` dispatches already default to `omp`. This plan introduces four judgment rungs mapped onto the tiers CE's own review skills already declare per persona — cheapest-capable, platform mid-tier, session-model (or an established high-capability review tier), and an above-CE escalation tier reached only on request or after repeated failure — and reuses the two existing `omp` rows for the cheap and standard rungs, adding one new `claude` `opus` row for the deep rung. Most judgment personas move off `claude` down to the `omp` Gemini seat; CE's own highest-stakes personas (`correctness-reviewer`, `security-reviewer`, `adversarial-reviewer`, and their document-review counterparts) keep a frontier model.

### Problem Frame

`agents.yaml` declares a single `claude-fable` worker for the `judgment` shape, so every judgment dispatch — sixteen `ce-code-review` personas, eight `ce-doc-review` personas, three `ce-simplify-code` personas, and any `ce-pov` call — resolves to the same row regardless of the persona's own declared risk tier. CE's installed skill docs (`ce-code-review/references/dispatch-reviewers.md`, `ce-doc-review/references/dispatch.md`, `ce-simplify-code/SKILL.md`) already fix which of three capability tiers each persona needs; the roster's single-row lookup overwrites that declaration rather than reading it. `mechanical` and `implementation` dispatches already default to `omp`, so `judgment` is the one shape whose default recipient is the most expensive model in the roster regardless of the work's actual weight.

### Key Decisions

- **Adopt CE's own three declared persona tiers as the roster's judgment hierarchy, plus one escalation tier above CE's range.** Governs R1, R9. (session-settled: user-directed — chosen over keeping one flat judgment row: CE already declares a deterministic per-persona tier mapping and a flat row silently overwrites that contract.)
- **Reuse the two existing `omp` rows for the cheap and standard rungs; add exactly one new `claude` row for the deep rung; add no new `omp` row.** Governs R1. (session-settled: user-directed — chosen over adding a dedicated `omp` row per rung: keeps the roster's seat count and the coordinator's brief-guidance table from growing.)
- **Lower `claude-fable-authoring`'s effort from `max` to `medium`, keeping `authoring` as the one remaining explicit exception to the omp-first principle.** Governs R4, R5. (session-settled: user-directed — chosen over moving `authoring` to `omp`: Compound Engineering's promotion-adapter chain (`docs/guides/configuration.md:95`) has no `omp` route, so the exception cannot be removed without a CE-side change, but its cost should still drop.)
- **The cross-model `codex` judgment pass is orthogonal to which rung a persona resolves to, and stays unchanged.** Governs R3. (session-settled: user-directed — chosen over folding `codex` into the rung ladder: the issue treats the `codex` pass as an independent safety net across every rung, not a tier of its own.)
- **Scope is the roster, its render-time consumers, and their tests and prose; issues #550, #557, and #558 are referenced as related context but not implemented here.** Governs Scope Boundaries. (session-settled: user-directed — chosen over bundling those issues in: each carries its own tracked acceptance criteria that #560's own completion checklist does not require.)

### Requirements

**Roster data**

- R1. The roster declares four judgment rungs — `judgment-cheap`, `judgment-standard`, `judgment-deep`, `judgment-escalation` — each resolvable through `agent-roster-lookup.tmpl`'s existing `rung` filter: `judgment-cheap` and `judgment-standard` are added to the existing `omp-flash-mechanical` and `omp-flash` rows respectively (alongside their current shapes), `judgment-deep` is carried by a new `claude-opus-judgment` row (`opus`, `xhigh`), and `judgment-escalation` is added to the existing `claude-fable` row.
- R2. `agent-roster-validate.tmpl` fails the render when no `omp` worker declares the `judgment` shape, mirroring the existing codex-judgment-minimum guard.
- R4. `claude-fable-authoring`'s effort is `medium` (down from `max`), and `agents.claude.settings.modelSettings.claude-fable-5-1.effortLevel` plus `elevation-dispatch.sh`'s `EFFORT` continue to mirror that same roster entry exactly, so `.ci/test-claude-settings-reconcile.sh`'s and `.ci/test-compound-engineering-overlays.sh`'s existing parity guards keep passing unweakened.
- R5. No roster worker declares `agent: claude`, `model: fable`, and `effort: max` together.

**Coordinator routing**

- R3. The coordinator's judgment routing table dispatches `judgment-deep` work to `claude` `opus` `xhigh` paired with the unchanged `codex` cross-model companion (identical to today's single row), and `judgment-cheap`/`judgment-standard` work to the corresponding `omp` row paired with that same unchanged `codex` companion, so the `codex` pass stays orthogonal to whichever primary agent a rung selects.
- R6. The coordinator's "an unrecorded `claude` implementation dispatch is a rule violation" sentence has a judgment-side counterpart ("an unrecorded `claude` judgment dispatch is a rule violation"), and the "a Unit without a mechanically checkable acceptance signal ... is never sent to an omp seat" sentence is scoped to say "Implementation Unit" so it no longer reads as blocking a judgment dispatch to an `omp` seat.
- R9. The `judgment-escalation` rung (carried by `claude-fable`) is not wired into the coordinator's primary judgment routing table; it stays reachable only through the existing three-consecutive-failure "most capable review agent" consult path (`agents-instructions.tmpl`) or an explicit user upgrade request for that run, so the default judgment routing path dispatches zero `fable` work.

**Tests and prose**

- R7. `CONCEPTS.md`'s "Judgment work" and "Model roster" glossary entries, and `README.md`'s and `AGENTS.md`'s model-roster paragraphs, describe the four-rung hierarchy and its CE-tier correspondence in place of the single flat judgment entry, and their worker count reads seven.
- R8. `.ci/test-agent-roster.sh` asserts: the new `claude-opus-judgment` row's model and effort, rendered through `agent-roster-lookup.tmpl` rather than a literal; the judgment routing table's new row count; the `omp`-judgment-minimum validation guard, positive and negative; and every existing fixture that renders the coordinator or everyone template still satisfies the new guard and the new per-rung lookups. Its retired "seven worker" stale-count guard (written when the roster shrank from seven workers to six) is removed, because seven becomes the correct, current count once `claude-opus-judgment` exists.

### Scope Boundaries

**In scope:** `home/.chezmoidata/agents.yaml`, `home/.chezmoitemplates/agent-roster-validate.tmpl`, `home/.chezmoitemplates/orchestration-coordinator.tmpl`, `home/dot_local/share/compound-engineering-overlays/skills/ce-plan/scripts/executable_elevation-dispatch.sh`, `.ci/test-agent-roster.sh`, `.ci/test-claude-settings-reconcile.sh`, `CONCEPTS.md`, `README.md`, `AGENTS.md`. `home/.chezmoitemplates/agent-roster-lookup.tmpl` and `home/.chezmoitemplates/orchestration-everyone.tmpl` need no edits: the lookup template's `rung` filter is already generic, and the everyone payload's `codex` judgment/fallback lookups are unaffected by the new rungs.

**Deferred to Follow-Up Work:**
- Issues #550 (omp launch-ceremony cost), #557 ("seat" terminology), and #558 (judgment-row unavailable-fallback wording) — named by #560 as related and recommended-first, but not required by its own completion checklist. Referenced in the pull request description, not implemented here.
- A CI guard that diffs the roster's rung mapping against CE's installed dispatch docs on every CE version bump (#560's "CE tier drift" risk) — left as a manual re-check tied to CE version bumps rather than new CI machinery, since #560's completion checklist does not require it and a source-diffing guard is a materially larger, separately-scoped change.

**Outside this product's identity:** Changing which specific personas CE assigns to which tier — that assignment is owned by the installed Compound Engineering plugin, not this repository; this plan only routes the roster's rungs to match CE's existing declaration.

### Assumptions

- No relevant upstream plan or brainstorm artifact exists for this issue (`docs/plans/` was checked; the closest-named files address different, sibling issues on the roster). Planning proceeds directly from the issue body per Phase 0.4 of `ce-plan`.
- This run is headless (`/lfg`, no synchronous user), so the Phase 0.7 scoping-synthesis confirmation is skipped per that phase's headless routing; the internal scope draft is recorded above instead.
- This run does not carry a `plan_model` directive and this refactor has no authentication, payments, migration, or external-API-contract risk surface, so the repository's default `plan_model` elevation (fable, size-gated to a Deep run or a Standard run with such a risk surface) does not apply; this plan is authored inline on the session model.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Per-rung coordinator lookups replace the single flat judgment lookup**, querying `agent-roster-lookup.tmpl` directly by `rung` (`judgment-deep`, `judgment-standard`, `judgment-cheap`) instead of by `shape` alone. No change to `agent-roster-lookup.tmpl` itself: its `rung` filter already matches an exact value with no wildcard-widening needed. Governs R1, R3.
- KTD2. **The judgment routing table gains three rows in place of today's one** (`judgment-deep`, `judgment-standard`, `judgment-cheap`), each pairing its primary recipient with the unchanged `codex` companion over the same brief. `judgment-escalation` stays out of the primary table: it is a named, addressable rung a future prose or template edit can reference, not a target this plan's coordinator changes route to — today it is reached only by convention, through the existing three-consecutive-failure "most capable review agent" language in `agents-instructions.tmpl`, which names no rung directly. Governs R3, R9.
- KTD3. **On-agent-unavailable and on-substantive-failure for every judgment row keep today's exact mechanism, generalized from one row to three: the review proceeds on the surviving one of that row's two paired recipients, recorded as degraded.** No new escalation ladder between rungs. The existing sentence bumping a degraded-codex `claude` reviewer to the `authoring` rung's effort stays scoped to `judgment-deep`, since that is the only rung whose primary recipient is `claude`. Governs R3.
- KTD4. **The rung a lead selects for a given persona is a judgment call the lead makes when reading CE's own dispatch documentation for that skill invocation, not a lookup keyed by persona name in this repository's own files.** This repository's roster and coordinator template stay persona-agnostic; the CE-tier-to-rung correspondence is recorded in `CONCEPTS.md`/`README.md`/`AGENTS.md` prose (R7) as the reference a lead consults, not as executable roster logic, because CE's persona list is owned by the installed plugin and can change on a CE version bump. Governs R7.
- KTD5. **The authoring-effort mirror chain (roster entry -> `modelSettings.claude-fable-5-1.effortLevel` -> `elevation-dispatch.sh`'s `EFFORT`) stays a value change only.** Both existing CI guards (`.ci/test-claude-settings-reconcile.sh`'s literal parity check, `.ci/test-compound-engineering-overlays.sh`'s dynamic roster-vs-overlay check) already read the roster's authoring entry dynamically except for one literal `"max"` in `.ci/test-claude-settings-reconcile.sh`, which must be updated to `"medium"` alongside the roster change. Governs R4.

### High-Level Technical Design

The judgment routing table's shape changes from one row to three; the table below is the target state (compare against the current single "Judgment work" row in `orchestration-coordinator.tmpl`):

| CE-declared tier (evidence) | Rung | Primary recipient | Paired with | On failure or unavailable |
|---|---|---|---|---|
| Cheapest-capable extraction/reasoning (`ce-doc-review/references/dispatch.md:13`) | `judgment-cheap` | `omp` `google-antigravity/gemini-3.8-flash` `low` (`omp-flash-mechanical`) | `codex` `gpt-5.6-luna` `max` (unchanged) | Proceeds on the surviving `codex` reviewer, recorded degraded |
| Platform mid-tier / balanced (`ce-code-review/references/dispatch-reviewers.md:47`, `ce-doc-review/references/dispatch.md:15`, `ce-simplify-code/SKILL.md:38`) | `judgment-standard` | `omp` `google-antigravity/gemini-3.8-flash` `high` (`omp-flash`) | `codex` `gpt-5.6-luna` `max` (unchanged) | Proceeds on the surviving `codex` reviewer, recorded degraded |
| Session model / established high-capability review tier (`ce-code-review/references/dispatch-reviewers.md:46`, `ce-doc-review/references/dispatch.md:14`) | `judgment-deep` | `claude` `opus` `xhigh` (new `claude-opus-judgment`) | `codex` `gpt-5.6-luna` `max` (unchanged) | Identical to today's single row |
| Explicit upgrade or repeated-failure consult (outside CE) | `judgment-escalation` | `claude` `fable` `medium` (`claude-fable`) | — (reached only via the three-consecutive-failure path, not the primary table) | n/a |

The rung a given persona resolves to is a lead-side reading of CE's own skill docs (KTD4), not a name this repository's templates hard-code.

### Sources & Research

The tier citations in the table above were re-verified directly against the installed `compound-engineering` v3.26.3 plugin during planning (`ce-code-review/references/dispatch-reviewers.md:24,44,46-47`, `ce-doc-review/references/dispatch.md:13-15`, `ce-simplify-code/SKILL.md:38`) — the quoted lines and line numbers match issue #560's citations exactly, so the tier mapping is current, not stale from the issue's filing date.

---

## Implementation Units

### U1. Roster and authoring-effort data

- **Goal:** Declare the four judgment rungs on their carrying roster rows, add the new `claude-opus-judgment` row, and lower the `authoring` rung's effort with its two mirrors kept in sync.
- **Requirements:** R1, R4, R5
- **Dependencies:** None
- **Files:**
  - `home/.chezmoidata/agents.yaml`
  - `home/dot_local/share/compound-engineering-overlays/skills/ce-plan/scripts/executable_elevation-dispatch.sh`
  - `.ci/test-claude-settings-reconcile.sh`
- **Approach:**
  1. In `agents.yaml`'s `roster.workers`, add `judgment` to `omp-flash-mechanical`'s `shapes` and `rung: judgment-cheap`; add `judgment` to `omp-flash`'s `shapes` and `rung: judgment-standard`.
  2. Add `rung: judgment-escalation` to the existing `claude-fable` entry (shape stays `[judgment]`).
  3. Add a new worker entry `claude-opus-judgment` (`agent: claude`, `model: opus`, `effort: xhigh`, `shapes: [judgment]`, `rung: judgment-deep`), with brief guidance following the existing per-model brief-table pattern (state scope literally, ask for every finding with confidence and severity — mirroring the `claude-sonnet` brief's review-specific clause since this is also a `claude` review seat).
  4. Change `claude-fable-authoring`'s `effort` from `max` to `medium`.
  5. Change `agents.claude.settings.modelSettings.claude-fable-5-1.effortLevel` from `max` to `medium` in the same file, and update its neighboring comment block (which currently reads "the claude-fable-5-1 leaf mirrors the roster claude authoring entry's effort") only if any part of it asserts the value is `max`.
  6. In `elevation-dispatch.sh`, change `EFFORT="max"` to `EFFORT="medium"` on its single existing line, and reword the trailing comment ("this repository raises elevation to max effort") since it is no longer raising to `max`; keep the edit to that one line so the file's diff against the pinned upstream copy stays exactly one line (`.ci/test-compound-engineering-overlays.sh`'s digest-reconstruction check requires this).
  7. In `.ci/test-claude-settings-reconcile.sh`, change the literal `"max"` to `"medium"` in the jq assertion for `modelSettings.claude-fable-5-1.effortLevel` (the check at present asserting `.["modelSettings.claude-fable-5-1.effortLevel"] == "max"`).
- **Patterns to follow:** The existing `claude-sonnet` entry already carries a `rung` alongside `shapes`; follow its field order and comment style. The `omp` rows' existing `shapes` lists are simple YAML flow sequences (`[mechanical]`); extend them in place (`[mechanical, judgment]`) rather than restructuring.
- **Test scenarios:**
  - Rendering `agent-roster-lookup.tmpl` with `agent: omp, shape: judgment, rung: judgment-cheap` against the committed roster returns `omp-flash-mechanical`'s model and `low` effort.
  - Rendering the same lookup with `rung: judgment-standard` returns `omp-flash`'s model and `high` effort.
  - Rendering `agent-roster-lookup.tmpl` with `agent: claude, shape: judgment, rung: judgment-deep` returns `opus` at `xhigh`.
  - Rendering the same lookup with `rung: judgment-escalation` returns `fable` at `medium`.
  - `chezmoi execute-template` against `agents.claude.settings.modelSettings.claude-fable-5-1.effortLevel` returns `medium`.
  - `elevation-dispatch.sh --emit-adapter fable` (the existing test hook) prints `--effort medium` in its argv.
  - `.ci/test-claude-settings-reconcile.sh` and `.ci/test-compound-engineering-overlays.sh` both pass unmodified in logic (only the one literal changed in the former).
- **Verification:** `home/.chezmoitemplates/agent-roster-validate.tmpl` still renders successfully against the changed roster (no duplicate id, no duplicate `(agent, rung)` pair); `.ci/test-claude-settings-reconcile.sh` and `.ci/test-compound-engineering-overlays.sh` pass.

---

### U2. `omp` judgment-minimum validation guard

- **Goal:** Fail the roster render when no `omp` worker declares the `judgment` shape, mirroring the existing `codex`-judgment-minimum guard.
- **Requirements:** R2
- **Dependencies:** None (uses synthetic fixture rosters, independent of U1's committed-roster edit)
- **Files:**
  - `home/.chezmoitemplates/agent-roster-validate.tmpl`
  - `.ci/test-agent-roster.sh`
- **Approach:**
  1. In `agent-roster-validate.tmpl`, add an `$ompJudgment` boolean beside the existing `$codexJudgment` one, set inside the same `range $shapes` loop when `$agent` is `omp` and the shape is `judgment`.
  2. After the existing `if not $codexJudgment` failure block, add a matching `if not $ompJudgment` failure block with a parallel message ("no `omp` entry declares the judgment shape").
  3. In `.ci/test-agent-roster.sh`, add a negative case next to the existing `codex-missing-judgment` case (around the `assert_render_fails codex-missing-judgment` block): an `omp-missing-judgment` roster (an otherwise-valid worker list where no `omp` entry lists `judgment`) that must fail with the new message.
  4. The existing `claude-two-rungs` positive fixture (`assert_render_ok claude-two-rungs`, two `claude` implementation entries plus `codex-luna`) declares no `omp` worker at all, so it fails once this guard exists. Add an `omp` entry with shape `judgment` to that fixture's worker list so it keeps passing; this is the positive case for the new guard, so no separate positive fixture is needed.
- **Patterns to follow:** Mirror the existing `$codexJudgment` variable, its `range` accumulation, and its post-loop `fail` block exactly — same shape, `omp` in place of `codex`.
- **Test scenarios:**
  - A worker list with a `codex` judgment entry but no `omp` judgment entry fails the render with a message naming the missing `omp` judgment declaration.
  - A worker list with both a `codex` and an `omp` judgment entry (and no other validation defect) renders successfully.
  - The existing `codex-missing-judgment` case still fails for its own reason (guard independence: the new check must not mask or duplicate the existing one).
- **Verification:** `.ci/test-agent-roster.sh`'s validation section passes, including the two new cases.

---

### U3. Coordinator judgment-routing rewrite

- **Goal:** Replace the coordinator's single flat judgment routing row with the three-rung table from the High-Level Technical Design, and extend the unrecorded-dispatch and acceptance-signal sentences.
- **Requirements:** R3, R6, R9
- **Dependencies:** U1 (the committed roster must carry the new rungs for the default render to produce meaningful table content), U2
- **Files:**
  - `home/.chezmoitemplates/orchestration-coordinator.tmpl`
- **Approach:**
  1. Replace the single `$judgeClaude` lookup with three: `$judgmentDeep` (`agent: claude, shape: judgment, rung: judgment-deep`), `$judgmentStandard` (`agent: omp, shape: judgment, rung: judgment-standard`), `$judgmentCheap` (`agent: omp, shape: judgment, rung: judgment-cheap`). Leave `$judgeCodex` unchanged.
  2. Replace the routing table's single "Judgment work" row with three rows in rung order (deep, standard, cheap), each following the High-Level Technical Design table: primary recipient plus the unchanged `codex` companion in the "First recipient" cell, and the generalized surviving-reviewer wording (KTD3) in both failure columns.
  3. In the paragraph beginning "Every `claude` launch from the judgment row selects...", scope that sentence to `judgment-deep` specifically (it is the only rung whose primary recipient is `claude`), and keep the degraded-`codex`-bumps-`claude`-to-`authoring`-effort sentence scoped the same way.
  4. In the sizing paragraph, add a sentence parallel to "An unrecorded `claude` implementation dispatch is a rule violation" for judgment: "An unrecorded `claude` judgment dispatch is a rule violation," placed next to the existing sentence so both dispatch classes share the same recorded-reason obligation.
  5. In the same paragraph, change "A Unit without a mechanically checkable acceptance signal ... is never sent to an omp seat" to name "An Implementation Unit without..." so it no longer reads as blocking a judgment dispatch — judgment work has no mechanically checkable acceptance signal by nature (its deliverable is the judgment itself) and was never meant to be covered by that sentence.
  6. Add one or two sentences (near the routing table or the brief-guidance table) naming the rung-selection responsibility from KTD4: the lead reads CE's own declared tier for the persona being dispatched and selects the matching rung, rather than this template naming personas.
- **Patterns to follow:** The existing single row's two failure-column phrasings ("`omp` `{{ $ompImpl.model }}` {{ $ompImpl.effort }} replaces a `codex` reviewer that errors" / "... replaces whichever reviewer is unavailable") are the model for the deep row, unchanged. The standard/cheap rows' failure columns are new prose per KTD3 ("review proceeds on the surviving `codex` `{{ $judgeCodex.model }}` {{ $judgeCodex.effort }} reviewer, recorded as degraded") — reuse the existing "recorded as degraded" phrase already used elsewhere in this file rather than inventing new terminology.
- **Test scenarios:**
  - Rendering the coordinator template against the committed roster produces a judgment section with three rows, each naming a distinct rung's primary recipient and the same `codex` companion pair.
  - Rendering against a fixture roster where `omp-flash-mechanical` and `omp-flash` carry distinct fake models proves the `judgment-cheap` and `judgment-standard` rows each name their own fixture's model, not each other's (same anchored-assertion style the existing KTD4 test already uses for the `claude`/`codex` judgment pair).
  - The rendered coordinator body contains "An unrecorded `claude` judgment dispatch is a rule violation."
  - The rendered coordinator body's acceptance-signal sentence names "Implementation Unit," not the bare word "Unit."
  - `grep -F 'rung' | grep -F` `` `fable` `` `` still finds no matching line (R4's existing guard keeps passing): no new sentence pairs the literal word "rung" with a backtick-quoted `` `fable` `` on the same rendered line.
- **Verification:** `orchestration-coordinator.tmpl` renders successfully against the committed roster and against the fixture rosters named above; the rendered body contains the three-row table and both new sentences.

---

### U4. Coordinator test-suite fixture and assertion overhaul

- **Goal:** Bring `.ci/test-agent-roster.sh`'s fixtures and assertions in line with the three-row judgment table, the new `claude-opus-judgment` row, and the corrected worker count.
- **Requirements:** R8
- **Dependencies:** U1, U2, U3
- **Files:**
  - `.ci/test-agent-roster.sh`
- **Approach:**
  1. Update every worker-list fixture in this file that is used to render the coordinator or everyone template (`one_seat_workers`, `two_seat_workers`, `stub_workers`, `two_entry_omp_workers`, and the `claude-two-rungs` positive-validation fixture) so at least one `omp` entry in each list declares the `judgment` shape (satisfying U2's new guard), and so any fixture rendered through the full `coordinator_wrapper` also carries `rung` values covering `judgment-deep`, `judgment-standard`, and `judgment-cheap` (satisfying U3's new lookups) — otherwise the render fails with "agent-roster-lookup.tmpl: agents.roster declares no ... entry" for the missing rung.
  2. Rewrite the R4 comment and its two assertions (currently "`fable` is the judgment model, never a sizing rung") to state that `fable` is the escalation judgment rung, reachable only outside the primary routing table, and is never a sizing rung; keep both existing `grep` assertions (fable-as-sizing-rung, author-exclusion) since their patterns still hold.
  3. Update the KTD4 `claude` judgment-pair assertion (`agent_seat_pair claude judgment ''`) to query `rung: judgment-deep` explicitly instead of an empty rung, so the assertion is pinned to the deep rung rather than "whichever `claude` judgment row sorts last."
  4. Add two new `agent_seat_pair` calls (`omp judgment` at `rung: judgment-standard` and `rung: judgment-cheap`) and matching anchor assertions in the rendered coordinator body, following the existing KTD4 pattern.
  5. Update R13's row-count assertions: the judgment routing table now contributes three rows instead of one (recompute the expected total against the current full table, whose other rows are unchanged), and the brief-guidance table's expected row count rises from six to seven for the new `claude-opus-judgment` worker.
  6. Add a dedicated assertion rendering `claude-opus-judgment`'s model and effort through `agent-roster-lookup.tmpl` (`agent: claude, rung: judgment-deep`) and asserting both appear in the rendered coordinator body — the "opus row" guard the issue's own completion checklist calls for, since `chezmoi apply` does not probe `claude`/`omp` roster entries.
  7. Update the "positive: the committed roster renders and prints six ids" check near the top of the file (`[[ $model_count -eq 6 ]] || fail "..."`, and its section-header comment) to `-eq 7`, since `agent-roster-validate.tmpl` prints one line per worker entry and the committed roster now has seven.
  8. In the "committed prose" section (R2/R6), remove the `grep -qF 'seven worker' ... && fail ...` guard (it is now testing for a phrase that becomes true and correct after U1 and U5), keeping the `five worker`, `codex-astra`, and `omp-flash-lite` stale-artifact guards unchanged.
- **Patterns to follow:** `agent_seat_pair` already accepts a `rung` argument (it is passed through to the `agent-roster-lookup.tmpl` wrapper) — the KTD4 block's `agent_seat_pair claude judgment ''` calls are the direct precedent for the new `omp judgment <rung>` calls.
- **Test scenarios:**
  - Every fixture that previously rendered against the full coordinator template still renders successfully after adding the required `judgment` shapes and rungs (no `agent-roster-lookup.tmpl` failure).
  - The `omp-missing-judgment` fixture from U2 still fails for the reason U2 introduced, not a different, newly-introduced failure.
  - `agent_seat_pair omp judgment` at each of `judgment-standard` and `judgment-cheap` resolves to the fixture's own distinct model/effort and appears in the corresponding row of the rendered coordinator body, with no cross-row leakage (mirroring the existing two-entry-Codex-stub leak checks).
  - The routing-table and brief-guidance row-count assertions pass against the committed roster's actual rendered output.
  - A dedicated assertion confirms `opus` and `xhigh` both appear in the rendered coordinator body attributable to the `claude-opus-judgment` lookup, not to an unrelated line.
  - The "seven worker" stale-count guard no longer exists in this file, and `grep -qF 'seven worker' README.md AGENTS.md` finds the phrase (proving U5's docs update landed) without this test failing.
- **Verification:** `.ci/test-agent-roster.sh` passes in full.

---

### U5. Root documentation rewrite

- **Goal:** Describe the four-rung judgment hierarchy and the corrected worker count in the repository's own glossary and README/AGENTS prose.
- **Requirements:** R7
- **Dependencies:** U1, U3
- **Files:**
  - `CONCEPTS.md`
  - `README.md`
  - `AGENTS.md`
- **Approach:**
  1. In `CONCEPTS.md`'s "Model roster" entry, generalize "a `rung` (`sonnet`) for the one Claude implementation entry" to note that a rung also distinguishes the judgment tiers, without re-deriving the tier table (cite the roster/coordinator files as the source of truth per the "one owner per rule" convention).
  2. In `CONCEPTS.md`'s "Judgment work" entry, replace "It is dispatched to the roster's frontier judgment entries" with a short description of the four-rung ladder and its CE-tier correspondence (cheapest-capable, mid-tier, session-model, escalation), citing the High-Level Technical Design's evidence paths rather than restating them at length.
  3. In `README.md`'s "Model roster" bullet, replace "Claude judgment on `fable` at medium effort" with a phrase naming the four judgment rungs and their agents/models/efforts, and change "six worker models" to "seven worker models."
  4. In `AGENTS.md`'s model-placement paragraph, replace "`claude` on `fable` (medium effort) for judgment" with the same four-rung description, and change "six worker entries" to "seven worker entries."
- **Patterns to follow:** Keep the existing sentence-dense style of both files (no new subheadings); extend the existing enumerations rather than restructuring the surrounding paragraph.
- **Test scenarios:** `Test expectation: none -- prose-only change with no executable behavior; covered by U4's stale-count-guard removal and by `.ci/test-agent-roster.sh`'s existing prose-vocabulary scan (every model id/rung name mentioned must already be in the roster).`
- **Verification:** `.ci/test-agent-roster.sh`'s committed-prose section (model-id vocabulary scan, retired-artifact scan) passes against the rewritten files.

---

## Verification Contract

| Command | Applicability | Done signal |
|---|---|---|
| `.ci/test-agent-roster.sh` | U1-U5 | Exits 0; every fixture render succeeds; new opus-row and omp-judgment-minimum assertions pass |
| `.ci/test-claude-settings-reconcile.sh <scratch-script-path>` | U1 | Exits 0; the updated `medium` literal matches the rendered leaf |
| `.ci/test-compound-engineering-overlays.sh <repo-root>` | U1 | Exits 0; the overlay's `EFFORT` line matches the roster's authoring entry dynamically |
| `chezmoi --source <repo-root> execute-template` against `agent-roster-lookup.tmpl` for each new `(agent, rung)` pair | U1, U3 | Each returns the expected model/effort from U1's Test scenarios |

## Definition of Done

- All five units land, each `.ci/*.sh` command above exits 0, and CI on the pull request head is green.
- No roster worker declares `agent: claude`, `model: fable`, `effort: max` (R5).
- The default `ce-code-review`/`ce-doc-review`/`ce-simplify-code` judgment path dispatches zero `fable` work (R9) and the rendered coordinator body's routing table shows three judgment rows, not one (R3).
- `CONCEPTS.md`, `README.md`, and `AGENTS.md` all read "seven worker" and describe the four-rung hierarchy (R7); no stale "six worker" text remains.
- No `Unapplied review findings` entry remains in the pull request description at merge time.
- No leftover experimental or abandoned-approach code remains in the diff.
