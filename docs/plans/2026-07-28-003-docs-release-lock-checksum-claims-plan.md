---
title: Correct Release-Lock Checksum-Verification Claims - Plan
type: docs
date: 2026-07-28
topic: release-lock-checksum-claims
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Correct Release-Lock Checksum-Verification Claims - Plan

## Goal Capsule

- **Objective:** Correct four wording sites in `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` (R12 line 87, KTD8 line 229, U5 test scenario line 314, the release-lock plan's DoD4 line 359) so the plan says digests are *recorded* in the lock for every tool whose upstream publishes one while only the pre-existing checksum consumers *enforce* them, with lock-wide enforcement explicitly deferred.
- **Product authority:** GitHub issue hyperlapse122/dotfiles#105 (repo maintainer).
- **Open blockers:** None. The issue's evidence was verified against the working tree: only `.chezmoiexternals/dev-tools.toml` (`[jq.checksum]`) and `.chezmoiexternals/ai-agents.toml` (claude, kimi, agent-browser, agy, pi, aoe) carry checksum blocks; k8s/vcs/system/fonts carry none. `.chezmoidata/releases.json` confirms the recorded-digest caveat: 19 of 41 tools have no `artifacts` block and agy's artifacts record `"sha256": null`, so "recorded" is only true where upstream publishes a digest.
- **Stop conditions:** any change required outside the one plan document, or any evidence that a `[tool.checksum]` block was actually added to a migrated externals file (which would flip the fix direction).

---

## Product Contract

### Summary

Rewrite four sentences in the merged release-lock plan so they describe what shipped: the lock records a sha256 for every tool whose upstream publishes one, but apply-time enforcement remains with the consumers that verified digests before the migration. The U5 test scenario must no longer direct a test that would fail against the release-lock plan's DoD4 (line 359).

### Problem Frame

The merged plan claims checksum *verification* was extended to all tools. The implementation deliberately added zero `[tool.checksum]` blocks to honor the byte-identical-render constraint, so for the migrated tools in dev-tools/k8s/vcs/system/fonts (and the recorded-only ai-agents tools) the digests are dead data at apply time. Issue #105 named three sites (R12, U5, the release-lock plan's DoD4); doc review of this plan found a fourth — the release-lock plan's KTD8 (line 229), which says "R12's extension applies to artifacts whose upstream exposes a digest" and still implies extended verification after R12 is reworded. Readers of the plan will believe download integrity now covers every tool, and anyone executing U5's remaining test task against the release-lock plan's DoD4 will write a failing test.

### Requirements

- R1. R12 (line 87) states that every tool whose upstream publishes a digest carries a recorded digest in the lock, while enforcement stays with the previously-verifying consumers, with lock-wide enforcement deferred.
- R2. KTD8 (line 229) no longer dangles an "R12's extension" claim: it states that recorded digests cover the artifacts whose upstream publishes one and that downloads without an upstream digest stay unverified exactly as today, consistent with the corrected R12.
- R3. The U5 test scenario (line 314) asserts recorded digests for tools that previously had none (where upstream publishes one) and unchanged checksum values for the previously-verifying consumers, instead of asserting new checksum enforcement.
- R4. The release-lock plan's DoD4 (line 359) carries the same recorded-vs-enforced distinction as R12 so R12, KTD8, U5, and DoD4 agree.
- R5. The change touches only `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md`; no source file that chezmoi renders changes, so rendered output is byte-identical.

### Scope Boundaries

- Non-goal: adding `[tool.checksum]` blocks to k8s/vcs/system/fonts or any migrated externals file.
- Non-goal: changing the release-lock data, resolvers, or `.chezmoitemplates/release-lock-ref.tmpl`.
- Deferred to follow-up work: lock-wide digest enforcement at apply time for the migrated tools.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Docs wording fix only; no rendered-output drift and no new checksum blocks.** (session-settled: user-directed — chosen over adding `[tool.checksum]` blocks to the migrated externals files now: the byte-identical-render constraint forbids rendered-output drift, and lock-wide enforcement is deferred to later work.)
- **KTD2. The corrected wording names the recorded-vs-enforced split at each site.** Each of the four sites states that digests are *recorded* in the lock for every tool whose upstream publishes one and *enforced* only by the previously-verifying consumers (jq in `dev-tools.toml`; claude, kimi, agent-browser, agy, pi, aoe in `ai-agents.toml`), so no site can be read in isolation as claiming lock-wide enforcement. Rationale: issue #105's three named sites drifted as a set, and doc review found KTD8 drifting with them; fixing only some leaves the contradiction in place.
- **KTD3. "Recorded" is qualified by upstream digest availability.** `.chezmoidata/releases.json` has 19 tools with no `artifacts` block (helm, kubectl, winbox, glab, compound-engineering, open-design, npm/pi-extension pins, and others) and agy recording `"sha256": null`, so the corrected wording says "recorded for every tool whose upstream publishes one" rather than "recorded for every tool" — matching the null caveat the release-lock plan's DoD4 already carries.

### Assumptions

- Issue #105 named three sites; doc review of this plan found the fourth (the release-lock plan's KTD8 line 229). All remaining checksum mentions in the release-lock plan were checked and make no extended-verification claim.
- The enumeration of previously-verifying consumers follows the issue: pi, aoe, jq, and the static-checksum ai-agents tools.

### Directional corrected wording

Directional guidance, not implementation specification; the implementer may adjust phrasing as long as R1–R5 hold:

- R12: "Every tool whose upstream publishes a digest carries a recorded digest in the lock; checksum enforcement stays with the consumers that verify today (jq and the static-checksum ai-agents tools), with lock-wide enforcement deferred."
- KTD8: "...the download stays unverified exactly as today; recorded digests cover the artifacts whose upstream publishes one, and enforcement stays with the pre-existing checksum consumers." (replaces the "R12's extension applies to..." clause)
- U5 scenario: "The lock records a digest for every tool that previously had none and whose upstream publishes one, and the previously-verifying consumers (pi, aoe, jq, and the static-checksum ai-agents tools) keep the same checksum values and remain the only enforcement points."
- DoD4: "Every locked artifact a consumer downloads carries a recorded sha256 where upstream publishes one (null only where the source exposes none, per Outstanding Questions); only the pre-existing checksum consumers enforce digests at apply time, with lock-wide enforcement deferred."

---

## Implementation Units

### U1. Correct the four checksum-verification claims

- **Goal:** Rewrite R12, KTD8, the U5 test scenario, and the release-lock plan's DoD4 so all four describe recorded digests plus pre-existing enforcement.
- **Requirements:** R1, R2, R3, R4, R5; KTD1, KTD2, KTD3.
- **Dependencies:** none.
- **Files:** `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` (lines 87, 229, 314, 359 as of issue #105 plus doc review).
- **Approach:** Edit the four sentences in place per the directional wording in the Planning Contract. Keep the R12/KTD/U5/DoD numbering, surrounding bullets, and all other plan content untouched. Do not let line numbers drift elsewhere — replace text in place, do not reflow the document.
- **Patterns to follow:** the plan's own existing requirement/DoD phrasing style.
- **Test scenarios:**
  - Happy path: after the edit, each of the four sites states digests are recorded (where upstream publishes them) and enforced only by the pre-existing consumers; a reader of any one site cannot conclude enforcement was extended.
  - Error path: no remaining sentence in the plan claims checksum *verification* or *enforcement* was extended to all tools (grep the document for the old claim shapes, including "R12's extension").
  - Integration: the four sites agree with each other and with the issue's evidence (the grep-confirmed checksum-block inventory and the lock's null/no-artifacts entries).
- **Verification:** `git diff` shows changes only inside the one plan file at the four sites; neither the old "extending checksum verification ... to all of them" claim nor the "R12's extension" clause appears anywhere in the document.

---

## Verification Contract

| Gate | Command / check | Done signal |
|---|---|---|
| Scope | `git diff --stat` | Only `docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` changed |
| Claim removal | `rg -n "extending checksum verification\|R12's extension" docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md` | Zero hits |
| Consistency | Read R12, KTD8, U5 scenario, DoD4 after edit | All four carry the recorded-vs-enforced distinction |
| Whitespace | `git diff --check` | Clean |

---

## Definition of Done

- DoD1. R12, KTD8, the U5 test scenario, and the release-lock plan's DoD4 each state that digests are recorded in the lock for every tool whose upstream publishes one and enforced only by the previously-verifying consumers, with lock-wide enforcement deferred.
- DoD2. The U5 test scenario no longer directs a test that would fail against the release-lock plan's DoD4 (line 359).
- DoD3. No file other than the one plan document changed; rendered output is unaffected.
- DoD4. No abandoned draft wording or stray edits remain in the diff.
