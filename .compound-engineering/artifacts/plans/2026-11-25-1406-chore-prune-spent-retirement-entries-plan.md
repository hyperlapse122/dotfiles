---
title: Prune Spent Retirement Entries - Plan
type: chore
date: 2026-11-25
topic: prune-spent-retirement-entries
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Prune Spent Retirement Entries - Plan

## Goal Capsule

- **Objective:** The repository's active config, checks, and docs name no spent one-time retirement or cutover entry; the retirement mechanisms remain ready for the next retirement.
- **Means:** One atomic change removes every spent entry together with the assertions and sentences that pin it.
- **Product authority:** The repository owner, for this single-user Nix flake. Scope is every spent entry regardless of which retirement created it. Mechanism rework, renames of live historically-named files, and retirement-lifecycle rules are not active scope.
- **Execution profile:** Nix modules, test fixtures, and repository docs; no host is switched as part of the change. One pull request carries the whole sweep.
- **Open blockers:** None. Both hosts run the current head, and every scope and approach decision is settled.
- **Who finishes:** `ce-work` implements this plan; the owner merges the pull request.

---

## Product Contract

Product Contract preservation: restructured, no scope change — R5 reworded to name the non-resurrection guards (R7) as its explicit exception and to add `tests/mise-settings.nix`, a pin research found; KTD4 records the trim boundary.

### Summary

One atomic change removes every spent retirement entry — the four retired casks and the `stablyai/orca` tap, the t3code retired settings entries and Antigravity instance migration, and the one-time mise config migration — together with the check assertions and doc sentences that pin them. The retirement mechanisms and non-resurrection guards stay ready for the next retirement, and the README's false retirement claim about Oh My Pi is corrected.

### Problem Frame

Both hosts run the current flake head, so every one-time removal step the chezmoi→flake cutover and the later tool retirements installed has already run: the retired casks are uninstalled, the retired settings keys and provider entries are gone, and the old T3 provider schema is migrated. Those steps now execute as no-ops on every apply — the retired-cask step probes four casks that are absent, the t3code declaration removes keys no settings file holds. Checks keep pinning entries that can no longer appear, and docs narrate removals that finished weeks ago. A config reader cannot tell managed state from finished transition state, and each retirement adds another spent layer that only a manual sweep removes.

### Requirements

**Retirement entries**

- R1. The `chatgpt`, `grok-bot`, `orca`, and `wifiman` cask entries and the `stablyai/orca` tap are removed from `modules/darwin/retired-casks.nix`.
- R2. The `reviewGuideModelSelection` retiredKey, the antigravity/grok/omp/omp-codex/codex retiredPaths, the `retiredAntigravityBinary` value, and the `instanceMigration` block carrying `retireAntigravity` are removed from `home/h82/t3code.nix`.
- R3. The Antigravity-specific retirement implementation in `scripts/agent-settings` is removed with its last declaring consumer; no `test_agent_settings.py` case goes with it, because none exists (verified — the behavioral coverage lives in the t3code fixtures that R5 trims).
- R4. The one-time `miseReplaceWritableConfig` activation entry is removed from `home/h82/shell/shell.nix`.

**Checks**

- R5. No check pins a removed entry as present or as an active removal step, with the non-resurrection guards of R7 as the explicit exception: the cask-specific assertions in `tests/darwin-config.nix` and `tests/darwin-outputs.nix`, the `tests/retired-brew-effects.py` fixture, the retirement expectations in `tests/t3code-traits.nix` and `tests/t3code-launch.py`, and the replace-entry assertions in `tests/mise-settings.nix` stop pinning them.

**Mechanisms**

- R6. The retirement mechanisms keep their behavior: the `modules/darwin/retired-casks.nix` step (sudo as the primary user, `--force`, never `--zap`, guarded failures), the agent-settings `remove`/`removePaths`/`migrateInstances` support, and the no-`--zap` guard with its `withoutStorePaths` regression cases are unchanged.
- R7. Non-resurrection guards stay: `grok-absent`, the `agent-instructions` retired-path zero-file assertions, `tests/agent-unmanaged.py`'s Antigravity-binary absence check, the managed-cask pins in `tests/darwin-config.nix`, and the grok-bot/chatgpt exclusion pins there remain as written.

**Docs**

- R8. No active document names a removed entry: the retired-cask lists in `docs/macos.md`, `docs/adding-a-host.md`, and `docs/repository-reference.md`, the one-time removal sentences in `docs/agent-routing.md`, and the retirement sentence in `README.md` stop enumerating spent entries.
- R9. `README.md` states Oh My Pi as an actively managed harness.
- R10. `docs/shell.md` drops its "Parity with the former chezmoi setup" section, and `docs/recovery.md` drops its retired-VM historical note.

### Key Decisions

- **Every spent entry, regardless of which retirement created it.** The same carrying cost attaches to each — a no-op step, a pinned check, a stale sentence — and both hosts being current makes every one safe to drop. (session-settled: user-directed — chosen over cutover-shims-only and casks-only scopes: the boundary the owner wants is "spent", not "from the cutover".) Governs R1–R4, R8–R10.
- **One atomic change.** (session-settled: user-directed — chosen over a staged per-family series: a single-owner repository gains nothing from an intermediate state.) Governs R1–R10.
- **Entries go; mechanisms and guards stay.** (session-settled: user-approved — chosen over removing the mechanisms with the entries: they enforce the standing retirement convention in `docs/contributing.md`, and the next retirement needs them unchanged.) Per-retirement entries are disposable once every host has applied. Governs R6, R7.
- **No retirement-lifecycle rule is added.** (session-settled: user-directed — chosen over a contributing.md prune rule: the owner wants the sweep alone.)

### Scope Boundaries

- Plan documents under `.compound-engineering/artifacts/plans/` stay untouched, including the cutover plan's stale statements: plans are historical records, and `AGENTS.md` says earlier plans do not bind new work.
- The retirement mechanisms are not removed or restructured; R6 and R7 carry what stays.
- `tests/non-nixos-scripts.nix`, `home/h82/security/non-nixos-secrets.nix`, and the `fake-non-nixos-secrets` fixture keep their historical names: they test live behavior, the cutover plan left the rename optional, and a rename is churn.
- No retirement-lifecycle rule or automatic pruning check is added.
- Oh My Pi stays managed; only the README's "retired" claim is corrected.
- No host is switched by this change.

### Dependencies / Assumptions

- Assumption (owner-confirmed this session): both hosts run the current head, which includes the OpenAI surface removal (PR #313), so every retirement entry's removal step has already run on its host — unconditionally on macOS, and on NixOS with the Home Manager generation that carried it.

### Sources / Research

- Grounding dossier with `file:line` evidence for every entry, check pin, and doc sentence: `/tmp/compound-engineering-1000/ce-brainstorm/cutover-cleanup-20261125/grounding.md` (machine-local, best effort; its facts are verified against the working tree).
- Planning research with the verbatim trim inventory, verified at `e39f722`: `/tmp/compound-engineering-1000/ce-plan-research/prune-20261125/repo-research.md` (machine-local, best effort).
- Institutional learnings behind KTD1 and the verification split: `/tmp/compound-engineering-1000/ce-plan-research/prune-20261125/learnings.md` (machine-local, best effort).
- `docs/contributing.md` "Tool retirement" — the standing convention that separates disposable entries from kept mechanisms.
- `.compound-engineering/artifacts/plans/2026-11-20-1002-refactor-t3-text-generation-claude-plan.md` — instructs removing the `reviewGuideModelSelection` retiredKey once every host has rebuilt past it.
- `.compound-engineering/artifacts/solutions/best-practices/store-hash-spells-forbidden-word-in-substring-check.md` — why the `--zap` guard and its regression cases stay.
- `.compound-engineering/artifacts/plans/2026-11-10-1545-refactor-nix-flake-cutover-plan.md` — origin of the transition machinery being pruned.
- `CONCEPTS.md` "Activation reassertion" — the host-apply timing that makes every entry spent.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Delete the retired-brew effects fixture whole, with its `darwin-outputs` section.** With both entry lists empty the step emits only the `retiredBrew()` definition and makes no brew call, so a kept fixture could only assert the empty no-op — a decorative assertion by this repo's mutation-round bar. A live mechanism guard would need a synthetic cask the real module does not declare, machinery with nothing live to guard. The no-`--zap` guard remains the step's standing check, and the next retirement re-teaches an effects check in the same commit it re-adds an entry, exactly as PR #315 did. Implements R5.
- KTD2. **Leave the retired-casks module code untouched; empty only the two entry lists.** `lib.concatMapStrings` over `[ ]` renders nothing, so the emitted activation keeps the harmless two-line `retiredBrew()` definition; gating emission on non-empty lists would change the mechanism behavior R6 fixes as unchanged and would be reversed by the next retirement anyway. Resolves the brainstorm's deferred emission question. Implements R1, R6.
- KTD3. **Drop the t3code `remove`/`removePaths`/`migrateInstances` arguments entirely rather than pass them empty.** `scripts/agent-settings` defaults all three (`remove` `:198`, `removePaths` `:226`, `migrateInstances` `:231`), and the local `declaration` already emits `remove = [ ]`; the ledger stays because `own = modelSelections` requires it. With the last consumer gone, the Antigravity-only `retire_antigravity` path in `scripts/agent-settings` goes with its validation, usage doc, and call site; the unknown-key validation then rejects a stray `retireAntigravity` on its own. Implements R2, R3.
- KTD4. **Non-resurrection guards are the explicit exception to R5.** `tests/grok-absent.nix`, `tests/agent-unmanaged.py:8`, the managed-cask pins, and the grok-bot/chatgpt exclusion pins in `tests/darwin-config.nix:732-737` name retired tokens to assert their absence — the standing "later switches must neither reinstall" rule — so they stay as written while every pin of presence goes. Implements R5, R7.

### Risks

- A check that partitions or iterates over the removed lists can keep an emptied side green while `nix flake check` stays green. The research grep inventory enumerated every reader of the removed entries; the Definition-of-Done search re-verifies at the end.
- A re-pointed assertion near a removed option can fail at evaluation instead of in the builder. This change deletes assertions whole rather than re-pointing them; the only kept assertions over the emptied lists (`tests/darwin-config.nix:702-710`) are verified to pass with empty lists.
- The darwin check builds need an aarch64-darwin builder this Linux workstation lacks. They evaluate locally and build in CI; the PR is declared ready only on that CI evidence.

### Sequencing

One pull request. U1 (darwin casks), U2 (t3code settings), and U3 (mise) are independent trims; U4 (docs) lands with them. The order below is review order, not dependency.

---

## Implementation Units

### U1. Empty the darwin retired-cask lists and trim the cask-pinning checks

- **Goal:** The retired-cask step keeps its mechanism and guards with empty entry lists, and every check that pinned the four casks or the tap stops pinning them.
- **Requirements:** R1, R5, R6, R7 (KTD2, KTD4).
- **Dependencies:** none.
- **Files:** `modules/darwin/retired-casks.nix`, `tests/darwin-config.nix`, `tests/darwin-outputs.nix`, `tests/retired-brew-effects.py` (delete).
- **Approach:**
  1. Empty `retired` and `retiredTaps` (`modules/darwin/retired-casks.nix:7-16`); trim the per-cask comments (`:22-33`) and keep the mechanism sentences — sudo-as-user, list-absence semantics, `--force` — in reduced form.
  2. In `tests/darwin-config.nix`, delete the cask-pinning assertions: the `:294-308` let-bindings, `:711-713` non-empty `retiredBrewCalls`, `:714-719` grok-bot block, `:723-731` ordering, and `:738-739` chatgpt scans. Keep `:702-710` (sudo shape and `retiredBrew() {` presence, both still true with empty lists), `:720-722` no-zap scan, `:23-46` filter machinery with its regression cases, `:437` mapping equality, and the `:732-737` exclusion pins (KTD4).
  3. In `tests/darwin-outputs.nix`, delete `:628-632` (the five retired-line variables) and `:652-658` (the retired presence/ordering `if` and the fixture invocation), leaving `:633-651` — the Home Manager line and the bundle, Xcode, KakaoTalk, and Flighty orderings — intact alongside the Brewfile cask equality (`:609-612`).
  4. Delete `tests/retired-brew-effects.py` (KTD1).
- **Patterns to follow:** PR #315's coupling lesson — a retired-list change and the check that pins it move in the same commit.
- **Test scenarios:**
  - `darwin-config` passes with empty lists: the sudo shape and function-definition assertions hold and the live no-zap scan stays green.
  - `darwin-outputs` passes with the retired section gone; Flighty still orders before Home Manager.
  - The `assertZapFilter` regression cases and the grok-bot/chatgpt exclusion pins still turn red when `--zap` or a retired cask is reintroduced.
- **Verification:** `nix fmt -- --ci` clean; `darwin-config` and `darwin-outputs` evaluate locally and build green on a darwin builder (see Verification Contract).

### U2. Strip the spent t3code retirement declarations and their checks

- **Goal:** The t3code agent-settings declaration carries no spent retirement or migration state, the agent-settings script loses its Antigravity-only path, and the t3code checks stop expecting any of it.
- **Requirements:** R2, R3, R5, R6 (KTD3, KTD4).
- **Dependencies:** none.
- **Files:** `home/h82/t3code.nix`, `scripts/agent-settings`, `tests/t3code-traits.nix`, `tests/t3code-launch.py`.
- **Approach:**
  1. Delete from `home/h82/t3code.nix`: `:31` `retiredAntigravityBinary`, `:145-152` `retiredKeys`, `:154-211` the ten `retiredPaths`, `:213-227` `instanceMigration` with `retireAntigravity`. Per KTD3 the declared settings become `(declaration settings) // { own = modelSelections; upsertPaths = [ opencodeInstructions ]; }` and the client settings become `declaration clientSettings` (drop the `:307-315` removePaths override). Keep the ledger and the live declared-disabled grok instance.
  2. Delete from `scripts/agent-settings`: the `retireAntigravity` usage doc (`:78-83`), the required-set allowance (`:467`), the validation (`:478-484`), `retire_antigravity` (`:487-524`), the call (`:542`), and its tuple slot.
  3. Delete from `tests/t3code-traits.nix`: `:81-147` (remove list, ten removePaths, `migrateInstances`), `:413-420` client codex prune, `:477-488` `@RETIRED-AGY@` substitution, `:506-514` the `retireAntigravity` block, and the `:372-379` seed.
  4. Delete from `tests/t3code-launch.py`: `exercise_retirement` (`:73-138`) and its `main` call, the absence assertions `:21-23`, `:50`, `:56`, and the seed inputs that exist only to feed them — the `:153` omp instance, the `:157` codex instance, the codex entries in the `:151` providers seed and the client seed, and the retired grok `config`/`environment` keys (`:154-156`). Keep `:20` (the grok instance stays declared-disabled), `:51` (owner-custom instances preserved, fed by the `:158` `custom-grok` seed), and the `:150` unrelated-key witness.
- **Patterns to follow:** the empty-declaration expectation shape in `.compound-engineering/artifacts/solutions/integration-issues/t3code-settings-json-value-outranks-repository-t3-json.md`.
- **Test scenarios:**
  - `t3code-traits` passes with `remove = [ ]` and no `removePaths` or `migrateInstances` in the expected base; the declared-disabled grok instance pins stay green.
  - `t3code-launch` passes with the retirement scenarios gone; owner-custom instances are still preserved.
  - `migrateInstances` with a stray `retireAntigravity` key fails validation once the allowance drops.
- **Verification:** touched shard builds green; `nix fmt -- --ci` clean.

### U3. Remove the spent mise config migration

- **Goal:** The one-time mise config migration is gone; the standing forced-file entry and its check remain.
- **Requirements:** R4, R5.
- **Dependencies:** none.
- **Files:** `home/h82/shell/shell.nix`, `tests/mise-settings.nix`.
- **Approach:**
  1. Delete `home.activation.miseReplaceWritableConfig` (`home/h82/shell/shell.nix:119-127`). Keep `:114-117` — `miseManagesGlobal` also gates the `xdg.configFile` force entry — and reword that comment's first sentence if it only narrates the one-time state.
  2. Delete from `tests/mise-settings.nix`: the `:34` doc bullet, the `:77-89` replace wiring, and the `:148-168` runtime section.
- **Test scenarios:**
  - `mise-settings` passes without the replace entry; the forced-file and settings-ls assertions are unchanged.
- **Verification:** touched shard build green; `nix fmt -- --ci` clean.

### U4. Align the docs with the emptied mechanisms

- **Goal:** No active document names a removed entry; mechanism docs describe behavior, not history; README states Oh My Pi as active.
- **Requirements:** R8, R9, R10.
- **Dependencies:** none.
- **Files:** `README.md`, `docs/macos.md`, `docs/adding-a-host.md`, `docs/repository-reference.md`, `docs/agent-routing.md`, `docs/shell.md`, `docs/recovery.md`.
- **Approach:**
  1. `README.md:47`: rewrite the Retired tools bullet — name no cask and no stale list; state Oh My Pi as actively managed.
  2. `docs/macos.md:41`: keep the mechanism sentences; drop "— today `chatgpt`, `grok-bot`, `orca`, and `wifiman` —", the untap clause, and the per-tool user-data enumerations.
  3. `docs/adding-a-host.md:190`: reduce "plus retirement of `grok-bot` and `orca` (`modules/darwin/retired-casks.nix`)" to the module mention.
  4. `docs/repository-reference.md:17`: trim the named-cask list to the module name.
  5. `docs/agent-routing.md`: `:55` drop "and activation removes a stored one"; `:59` delete the sentence; `:61` rewrite the paragraph around the standing declared-disabled grok instance, keeping the T3 0.1.9 session-history fact; `:63` delete the paragraph.
  6. `docs/shell.md`: delete `## Parity with the former chezmoi setup` (`:27-48`).
  7. `docs/recovery.md`: delete the `### Historical note on the retired VM identity` subsection (`:236-238`), folding its still-true leak caveat — pre-rotation ciphertext in Git history is decryptable by the retired VM identity — into the surrounding rotation guidance as a current fact.
- **Test expectation:** none — documentation alignment; the repo's doc checks are the proof.
- **Verification:** `agent-instructions` check green (required by `docs/contributing.md` when `docs/agent-routing.md` changes); markdown lint via `./scripts/agent-check`.

---

## Verification Contract

| Command | What it proves | Where it runs |
| --- | --- | --- |
| `nix fmt -- --ci` | Touched Nix is formatted | local |
| `./scripts/agent-check` | Repo checker, including markdown lint of changed docs | local |
| `nix flake check` | All-system check evaluation and local-system builds | local (Linux) |
| `nix build --no-link .#checkShards.<name>` for each touched shard | Shard builds for the t3code and mise checks | local, shard names from `tests/check-shards.nix` |
| `checks.aarch64-darwin` builds (`darwin-config`, `darwin-outputs`) | Darwin check builds | CI `full-ci` label job, or a darwin host |
| `agent-instructions` | Instruction receipts after the `docs/agent-routing.md` change | local |
| PR CI per `docs/contributing.md` | `host-checks`, `vm-checks`, `build`, and `build-darwin` green on the head | CI, before the PR is declared ready |

Mutation evidence owed: none new. The change deletes assertions of removed behavior; every surviving assertion of the kept mechanisms (`assertZapFilter` regression cases, exclusion pins, no-zap scan) keeps the mutation evidence it already carries.

---

## Definition of Done

- A repository-wide search over active config, tests, scripts, and docs — excluding `.compound-engineering/artifacts/plans/`, `.compound-engineering/artifacts/solutions/`, git history, and the standing guards named in KTD4 — finds no reference to the removed entries.
- `nix fmt -- --ci` and `./scripts/agent-check` pass locally, and the PR carries the CI evidence `docs/contributing.md` requires before it is declared ready.
- No dead binding, unused import, stale comment, or scratch from an abandoned attempt remains in the diff.
- Each unit's named checks pass after its trim.
