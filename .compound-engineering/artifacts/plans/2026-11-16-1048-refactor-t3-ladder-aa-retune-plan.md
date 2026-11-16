---
title: T3 Delegation Ladder AA Retune - Plan
type: refactor
date: 2026-11-16
topic: t3-ladder-aa-retune
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# T3 Delegation Ladder AA Retune - Plan

## Goal Capsule

- **Objective:** Compound Engineering children that T3 Code delegates to Antigravity finish faster at an Artificial Analysis Intelligence Index score close to the current ladder, and Synthetic children run on rungs ordered by that index, without the slowest measured Synthetic model.
- **Means:** Retune the Antigravity and Synthetic rows of the T3 CE model-selection ladder, and pin Antigravity thinking levels per rung (KTD1, KTD2).
- **Product authority:** The repository owner, through this brainstorm. The Claude and Codex rows are not active scope.
- **Execution profile:** One pull request, stacked on top of the stack that holds PRs #190 and #191 with `gh stack add`, per the owner's instruction. Another session is assembling that stack; this work does not restack, rebase, or edit those branches.
- **Stop conditions:** Stop if the stack top cannot be identified when the PR is created, or if the rebased template no longer has the T3 CE model-selection section in the shape this plan edits.
- **Open blockers:** None.

---

## Product Contract

### Summary

The Antigravity row moves every child rung to Gemini Hydrogen, with an explicit thinking level per rung: xhigh at the top, high in the middle, and medium at the bottom.
The Synthetic row shifts down one family: Kimi at the top, GLM in the middle, and GLM Flash at the bottom, which drops DeepSeek Flash.
The routing documentation records the Artificial Analysis scores behind the change and names the settings that have no local measurement.

### Problem Frame

Antigravity's top rung, Gemini 4 Carbon at high, took about 260 seconds per child in the 2026-11-14 measurement, about five times as long as Hydrogen.
The ladder leaves effort unset, so children follow T3's default, and T3 has since changed Hydrogen's default from high to xhigh.
Middle and bottom Antigravity children now run at xhigh, which that measurement found slower with no gain in passing repairs.
The Synthetic row also runs against the Artificial Analysis Intelligence Index (15 Nov '26): its bottom rung, DeepSeek V4.1 Flash, scores above its top rung, GLM-5.3, and the orchestrator family Kimi K3.1 Pro scores far above both.

| Setting | AA score | Local completion time (2026-11-14 or 2026-10-21) |
| --- | --- | --- |
| Gemini 4 Carbon high | 60 | 261 s, 262 s |
| Gemini 4 Hydrogen xhigh | 54 | 59 s, 77 s |
| Gemini 4 Hydrogen high | 51 | 51 s, 51 s |
| Gemini 4 Hydrogen medium | 41 | not measured |
| Kimi K3.1 Pro | 46 | not measured (Kimi K3 high: 10-14 min as a review peer) |
| GLM-5.3 | 32 at max | 24-25 min at max as a review peer |
| GLM-5.3 Flash | 28 | 10-19 min at high as a review peer |
| DeepSeek V4.1 Flash 1017 | 33 at max, 29 at high | 48 min at max, 101 min at high as a review peer |

### Key Decisions

- **Scope covers the Antigravity and Synthetic rows only.** Governs R1-R7. (session-settled: user-directed — chosen over Antigravity only and over a full four-row review: the Synthetic ordering contradicts the AA scores, while the Claude and Codex rows match them and Codex has its own replay evidence.)
- **Antigravity top rung uses Hydrogen xhigh instead of Carbon high.** Governs R1. (session-settled: user-approved — chosen over Carbon medium and keeping Carbon high: AA 54 still exceeds Opus 5.5 high and Sol high, at about a quarter of Carbon's local completion time, accepting Hydrogen's 1/2 versus Carbon's 2/2 on the local repair task.)
- **Antigravity middle rung pins Hydrogen high.** Governs R2. (session-settled: user-approved — chosen over xhigh and medium: same local pass rate as xhigh and faster, and the level the 2026-11-14 decision meant to use.)
- **Antigravity bottom rung uses Hydrogen medium.** Governs R3. (session-settled: user-approved — chosen over Hydrogen low, Hydrogen high, and Gemini 3.8 Flash high: AA 41 is above every other provider's bottom rung, without the loop risk seen at a low effort.)
- **Synthetic top rung moves to Kimi K3.1 Pro.** Governs R5. (session-settled: user-approved — chosen over keeping GLM: AA 46 against GLM's 32, in the same column as the Kimi orchestrator.)
- **Synthetic middle and bottom rungs become GLM and GLM Flash, dropping DeepSeek Flash.** Governs R6. (session-settled: user-approved — chosen over keeping DeepSeek Flash at the bottom: it was the slowest Synthetic model measured, and the new order follows the AA scores.)
- **The change lands on AA scores and existing measurements, without a new benchmark.** Governs R8. (session-settled: user-approved — chosen over a two-sample T3 benchmark of the unmeasured settings: faster to land, and the documentation names what is unmeasured.)

### Requirements

**Antigravity row**

- R1. A top-rung Antigravity child runs Gemini Hydrogen at thinking level xhigh.
- R2. A middle-rung Antigravity child runs Gemini Hydrogen at thinking level high.
- R3. A bottom-rung Antigravity child runs Gemini Hydrogen at thinking level medium.
- R4. Antigravity thinking levels are passed explicitly, so a later change to T3's default does not move them; this is a second exception, beside Codex, to the rule that ladder-selected children set no effort.

**Synthetic row**

- R5. A top-rung Synthetic child runs Kimi K3.1 Pro, and the row's family wording resolves to K3.1 Pro rather than Kimi K3 when both are listed.
- R6. A middle-rung Synthetic child runs GLM and a bottom-rung child runs GLM Flash; Synthetic children keep effort unset.

**Unchanged behavior**

- R7. The Antigravity orchestrator column stays Gemini Carbon, the Synthetic orchestrator column stays Kimi, and an effort named by the user's prompt or CE configuration still wins over the ladder.

**Evidence**

- R8. The routing documentation records the AA Intelligence Index scores (15 Nov '26) behind each new rung, keeps the existing local measurements, and states which new settings have no local measurement.

### Scope Boundaries

- The Claude and Codex rows, and their effort rules, stay as they are.
- No Grok row is added.
- No new T3 benchmark runs as part of this change.
- Synthetic `max` effort is out of reach: Pi lists `thinking` levels only up to `high`, so the AA `max` scores are an upper bound, not the configured setting.

### Dependencies / Assumptions

- T3 capability discovery on 2026-11-16 lists `thinking_level` values low, medium, high, and xhigh for `gemini-4-hydrogen`, with xhigh as the default.
- Pi lists both `Kimi-K3` and `Kimi-K3.1-Pro`; the newest-of-family rule alone may not single out K3.1 Pro.
- AA scores measure intelligence across nine evaluations, not completion time or this repository's tasks; the speed claims for unmeasured settings are expectations.

### Sources / Research

- `home/h82/agents/instructions/instructions.md.tmpl` (T3 CE model selection) and `docs/agent-routing.md` (Gemini selection evidence), which AGENTS.md requires to change together.
- `.compound-engineering/artifacts/solutions/best-practices/benchmark-cross-model-review-peers-in-t3-code-before-changing-them.md` for the Synthetic peer timings.
- Artificial Analysis Intelligence Index v5.0.1, chart dated 15 Nov '26, supplied by the owner.
- Product Contract preservation: Product Contract unchanged except the Objective, which now limits the speed claim to Antigravity (the Synthetic middle rung moves from GLM Flash to the slower GLM). The two open points in Dependencies / Assumptions, Hydrogen `thinking_level` options and Kimi K3.1 Pro family resolution, are resolved by KTD2 and KTD1.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The Synthetic top rung names the family `Kimi Pro`.** The ladder already resolves a family to its newest listed model, and `Flash` already narrows a family by name; `Pro` narrows it the same way, so K3.1 Pro wins over Kimi K3 without naming a version that a newer build would make stale. The orchestrator column keeps `Kimi`. Governs R5.
- KTD2. **Antigravity thinking levels travel as `thinking_level` in `target.options`.** T3 capability discovery lists `thinking_level` as the Antigravity option for every Gemini model. The effort paragraph gains an Antigravity sentence beside the Codex one, naming the level per rung. Governs R1, R2, R3, R4.
- KTD3. **Synthetic children keep effort unset.** Pi's `thinking` options stop at `high`, and nothing in this change measured a better Synthetic level. Governs R6.
- KTD4. **The evidence lands in `docs/agent-routing.md` beside the existing Gemini evidence.** A new subsection records the AA scores (15 Nov '26) per rung for both rows, keeps the 2026-11-14 table, and replaces the sentence that says the ladder leaves Antigravity effort unset. Governs R8.

### Assumptions

- The T3 receipt in `tests/agent-instructions.py` covers the rendered T3 branch only, so the four ordinary receipts and the T3 launch baseline in `tests/lib/t3code-launch-manifest.nix` stay unchanged. The edited section sits inside the `.t3` branch of the template.
- Kimi K3.1 Pro has no local timing as a cross-model review peer. Kimi K3 at high took 10-14 minutes, inside the 1210-second no-person peer deadline; a slower K3.1 Pro would surface as a missed peer in the first unattended review.
- PRs #190 and #191 also edit the template and the T3 receipt. The receipt this PR ships must be computed on the rebased stack top, not on `main`.

---

## Implementation Units

### U1. Retune the ladder in the shared template

- **Goal:** The rendered T3 instructions carry the new Antigravity and Synthetic rows and the Antigravity effort rule.
- **Requirements:** R1-R7; KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `tests/agent-instructions.py`.
- **Approach:**
  1. Change the Synthetic row to `Kimi | Kimi Pro | GLM | GLM Flash` and the Antigravity row to `Gemini Carbon | Gemini Hydrogen | Gemini Hydrogen | Gemini Hydrogen`.
  2. Add one sentence after the family rule saying that a family named with `Pro` includes only Pro models.
  3. In the effort paragraph, add the Antigravity exception: pass `thinking_level` `xhigh` for a top-rung child, `high` for a middle-rung child, and `medium` for a bottom-rung child in `target.options`.
  4. Update the `t3` value in `EXPECTED` to the new render's SHA-256.
- **Patterns to follow:** The existing Codex exception sentences in the same paragraph.
- **Test scenarios:**
  - The `agent-instructions` check passes with the new `t3` receipt and the unchanged ordinary receipts.
  - Reverting any one of the edits makes the `t3` receipt assertion fail.
- **Verification:** The `agent-instructions` check builds on the rebased stack top.

### U2. Mirror the ladder and record the evidence

- **Goal:** `docs/agent-routing.md` matches the template and explains the change.
- **Requirements:** R8; KTD4.
- **Dependencies:** U1.
- **Files:** `docs/agent-routing.md`.
- **Approach:**
  1. Copy the U1 text changes into the routing doc's T3 CE model selection section.
  2. Add an AA evidence subsection with the per-rung scores from the Product Contract table, naming Hydrogen medium, Kimi K3.1 Pro, and GLM-5.3 at Pi's default as unmeasured locally.
  3. Replace the sentence about Antigravity effort staying unset, and note that the Hydrogen default moved from high to xhigh after 2026-11-14.
- **Test expectation:** none -- documentation; the `agent-instructions` check reads this file as an input and must still build.
- **Verification:** `markdownlint-cli2` reports no issues and the doc's ladder table matches the template's.

---

## Verification Contract

| Gate | Command or check | Applies to |
| --- | --- | --- |
| Whitespace | `git diff --check` | U1, U2 |
| Markdown | `markdownlint-cli2` on changed Markdown | U2, this plan |
| Instructions | `nix build --no-link .#checks.x86_64-linux.agent-instructions` | U1, U2 |
| CI | Light shards on the PR; `full-ci` evidence per AGENTS.md before declaring ready | PR |

No Nix file changes, so `nix fmt -- --ci` has nothing to check beyond the existing tree.

---

## Definition of Done

- U1 and U2 are in one commit series on a branch stacked on top of the #190/#191 stack.
- The `t3` receipt matches the render on that stack top, and the `agent-instructions` check passes locally.
- The template and `docs/agent-routing.md` show the same ladder and effort rules.
- No abandoned-attempt edits remain in the diff.
