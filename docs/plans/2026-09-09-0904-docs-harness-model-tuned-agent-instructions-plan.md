---
title: Harness- and Model-Tuned Agent Instruction Core - Plan
type: docs
date: 2026-09-09
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Harness- and Model-Tuned Agent Instruction Core - Plan

## Goal Capsule

**Objective:** A person reading any of the three deployed instruction files can tell, from that file alone, when to open a skill before acting and how to resolve two rules that disagree — and the file says it in the style the model reading it responds to, without contradicting a rule already in the same file.

**Means:** Add one shared skills-and-precedence section plus a second harness-gated paragraph to `.chezmoitemplates/agents-instructions.tmpl`, assert the new paragraph against committed fixtures in `.ci/test-agent-instructions.sh`, and update the render contract in `AGENTS.md` (KTD1, KTD2, KTD3).

**Authority hierarchy:** `.chezmoitemplates/agents-instructions.tmpl` is the only edit site for instruction text. `AGENTS.md` records the repository contract for that template. `.ci/test-agent-instructions.sh` is the enforcement gate and must match both.

**Stop conditions:** Stop and report if a proposed guidance sentence contradicts an existing MUST in the core, or if the fixture comparison cannot be added without weakening an existing needle.

**Execution profile:** Documentation and CI change. No runtime code. Verification is the render gate plus a read-through of each rendered file.

**Tail ownership:** LFG owns commit, push, PR, and CI watch.

## Product Contract

### Summary

Add two things to the shared agent-instruction core. First, a bounded rule that an agent opens the tool, platform, or repository-procedure skill that already covers its next action before taking that action, together with a precedence rule that says how the core, a repository supplement, and a skill compose when they disagree. Second, a per-harness paragraph that tunes the core to the model family the harness runs, using each vendor's current prompting guidance. Assert the new harness paragraph byte-for-byte against a committed fixture, and update the `AGENTS.md` render contract to match.

### Problem Frame

The core is a large policy file written once for all three harnesses. Three gaps follow from that.

The core never tells an agent to look at its skill list. It names the `orchestration` skill for dispatch, but nothing directs an agent to open the `glab` skill before a GitLab command, or a repository skill before a build. Agents improvise steps that a shipped skill already specifies. This is a judgment call from the operator's own sessions, not a measured rate; it is why R15 asks for a checkable rendered outcome rather than a behavioral metric the repository cannot produce.

The core also carries no conflict rule. It states local precedence in several places — the executable-selection rule over skill defaults, the repository supplement's stricter rules, the `lfg` autopilot override — but never a general order. An agent facing two rules that disagree has to invent one.

The core carries no model-family tuning either, and the three harnesses run three different model families with different failure modes. Claude models over-verify and over-narrate when a prompt adds verification scaffolding. Codex models degrade on padded or contradictory instruction stacks and need the autonomy boundary stated once. Gemini Flash models follow instructions literally, answer tersely, and are harmed by chain-of-thought scaffolding written for older Gemini versions. One undifferentiated instruction file cannot correct all three.

**The volume trade this plan accepts.** The remedy adds text to a stack the diagnosis calls padding-sensitive. The plan accepts that for two reasons, and R14 bounds it. The precedence rule is a conflict resolver, so it removes ambiguity rather than adding another mandate. Each tuning paragraph replaces guessing with one family's calibration and is capped at six sentences. A later editor who wants to grow these paragraphs should read this trade first.

The template already has a harness gate, but the CI render gate strips exactly one prefix (`This harness is `) and the `AGENTS.md` contract names exactly that prefix. Any second harness-gated paragraph fails the peer-render diff until both are widened.

### Requirements

**Skills and precedence**

- R1. The core instructs the agent to review the harness's available skills and open the most specific skill that covers its next action, plus any skill the user names, before taking that action. The trigger is a next action that touches a tool, platform, or repository procedure a skill description names; a task with no such match proceeds without opening a skill. A further skill is opened only when a concrete step requires it.
- R2. The skills rule states that it grants no authority a rule elsewhere in the core withholds, and that it creates no mandatory workflow routing — the existing `Do not add mandatory ce-work/ce-debug routing here` sentence keeps deciding workflow selection.
- R3. The core states how the core, a repository supplement, a skill's instructions, and the harness's own defaults compose when they disagree, and states that the core's absolute prohibitions — secrets, destructive actions, and dispatch routing — are outside that composition and bind regardless of where the conflicting instruction comes from.
- R14. Every example named in R1 through R3 renders on every supported OS. No sentence in the shared section names a rule that an OS gate can remove from the file.
- R4. R1 through R3 and R14 render identically on all three harnesses.

**Per-harness model tuning**

- R5. Each harness receives one paragraph tuned to the model family it runs, and receives no other harness's paragraph.
- R6. The Claude paragraph tells the agent not to add verification or re-check passes beyond those an instruction or acceptance criterion already names, to hold the requested scope, to lead with the outcome, to match a written document's length to its substance, to keep narration to one sentence before the first tool call plus a change of direction, and to correct an earlier statement only when the error changes the user's decisions.
- R7. The Codex paragraph tells the agent to keep to the smallest sufficient instruction set, to resolve a conflict by the precedence rule rather than satisfying both sides, to read reasoning effort from configuration rather than asking for more thinking in prose, to state the goal, the boundary, and the definition of done before the first tool call, to batch independent reads, to calibrate verification to the risk of the change, and never to invent an identifier, version, price, or path.
- R8. The Antigravity paragraph tells the agent that the model follows a direct instruction literally and answers tersely, so it asks for the elaboration it wants rather than assuming it, and omits chain-of-thought scaffolding, role framing, and repeated restatement that were workarounds for older Gemini versions. Its two authoring clauses — put a long context before the instruction it anchors, and leave sampling and thinking level to configuration — are stated as rules for the briefs and prompts the agent writes for a Gemini-family worker, not as something the reading session can apply to its own input.
- R9. Each harness paragraph starts with a single stable prefix that the render gate can strip, and that prefix is distinct from `This harness is `.
- R15. No tuning paragraph names a model point release or a model id. It names the family and defers the effort level to configuration, so a point-release change needs no edit here.
- R16. Each tuning paragraph is at most six sentences.

**Enforcement**

- R10. `.ci/test-agent-instructions.sh` strips both harness prefixes before the peer-render diff, so the three renders still compare equal outside their harness paragraphs.
- R11. `.ci/test-agent-instructions.sh` compares each render's `This harness runs ` line byte-for-byte against a committed per-harness fixture, and asserts that the line appears exactly once per render.
- R12. `.ci/test-agent-instructions.sh` asserts the new shared skills and precedence sentences as positive needles.
- R13. `AGENTS.md` states the widened contract: which prefixes are harness-gated, what each owns, and that all three renders match outside them.

### Success Criteria

- SC1. Each of the three rendered files, read end to end, contains no sentence that contradicts another sentence in the same file. This is the check the `.ci` gate cannot make and a reader can.
- SC2. The skills rule in each render names a trigger a reader can evaluate without opening a skill first.
- SC3. Each tuning paragraph is six sentences or fewer and names no model id.

### Scope Boundaries

In scope: `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, `.ci/fixtures/`, and `AGENTS.md`.

Out of scope, and deliberately so:

- Changing declared models or effort levels in `.chezmoidata/agents.yaml`. The model list in the request is context for tuning the prose, not an instruction to re-declare configuration. R15 keeps the prose independent of those declarations, so the two cannot drift.
- Rewriting, shortening, or reordering existing rules in the core. The change is additive. A rewrite risks dropping a MUST that the render gate's needles do not cover.
- Retrofitting fixture comparison onto the existing `This harness is ` lines. R11 closes the CI header's known gap for the new prefix only; the old prefix keeps its per-sentence needles and its recorded gap.
- Measuring whether agent sessions actually improve. See Open Questions.

### Open Questions

- Q1 (deferred, non-blocking). Whether the tuning paragraphs change real session behavior cannot be measured in this repository — there is no session-outcome harness, and building one is a separate project. SC1 through SC3 check the artifact, not the outcome. Revisit if a session-telemetry surface ever exists.

### Sources

- Anthropic, *Prompting Claude Opus 5*, `https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5` — verbosity, over-verification, scope expansion, self-correction narration, subagent spawning. Read 2026-09-09.
- OpenAI, *Codex Prompting Guide*, `https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide` — smallest sufficient instruction set, contradictory-instruction sensitivity, effort set in configuration, risk-calibrated verification, parallel reads, never invent values. Read 2026-09-09.
- Google, *Gemini 3 developer guide*, `https://ai.google.dev/gemini-api/docs/gemini-3` — direct instructions, lower default verbosity, instruction-last context ordering, default sampling, thinking level in configuration. Read 2026-09-09.
- `.chezmoitemplates/agents-instructions.tmpl:43-49` — the existing harness gate this plan extends. Lines 23-27 are the OS gate, a different construct.
- `.ci/test-agent-instructions.sh` — `strip_harness_paragraph`, the `HARNESS_NEEDLES` table, the `NEEDLES` list, and the `KNOWN GAP` header.
- `AGENTS.md:68` — the current one-prefix render contract.

## Planning Contract

### Key Technical Decisions

KTD1. **A second harness-gated paragraph with the prefix `This harness runs `, not an append to the existing `This harness is ` line.** The existing line is the file-tool contract; the new one is model-family behavior. Keeping them separate keeps each line diffable and lets a reader see which contract changed. A distinct literal prefix also gives the render gate a clean strip predicate. Governs R5, R9, R10.

KTD2. **Widen `strip_harness_paragraph` to an extended-regex alternation over both prefixes.** Replace `grep -v '^This harness is '` with `grep -vE '^This harness (is|runs) '`. This is the smallest change that keeps the peer-render diff meaningful; an unanchored or broader pattern would strip shared prose and hide a real divergence. Governs R10.

KTD3. **Assert the new harness line against a committed fixture, not against per-sentence needles.** The gate's `KNOWN GAP` header names byte-for-byte fixture comparison as the proper fix and per-sentence needles as the workaround. A needle list is only as complete as the maintainer who last extended it: a sentence appended to a harness line passes the peer diff (the line is stripped) and passes the gate (nothing asserts row coverage). Three small fixture files close that hole for the new prefix at lower cost than a needle per sentence, and they keep the assertion surface free of prose that R15 expects to churn. Governs R11.

KTD4. **The skills rule sits in its own section immediately after the file header paragraph, before `## Writing and language`.** It governs the first action of a task, so it must be read before the rules it routes into. Governs R1, R4.

KTD5. **Precedence is stated as a composition rule, not a flat ranking.** A flat order would make the shared core outrank a repository supplement's stricter local rule, which inverts the relationship the header paragraph already sets, or would put a user's conversational instruction above the core's absolute prohibitions. The rule therefore says: a supplement may only add or tighten, and where it tightens, the tighter rule governs; a skill's instructions and the harness's own defaults yield to both; and the core's secrets, destructive-action, and dispatch-routing prohibitions sit outside the rule entirely. Existing local precedence sentences keep their own text and are not restated. Governs R3.

KTD6. **The tuning paragraphs name a model family and nothing narrower.** A harness serves more than one model and its declared model changes on its own schedule; `.chezmoidata/agents.yaml` declares one Codex model and no Antigravity model at all. Naming a point release would put a value into deployed prose and into the CI fixture that neither source of truth controls. The paragraph names the family, and the effort level stays a configuration concern. Governs R6, R7, R8, R15.

### Assumptions

- The model list in the request describes the operator's live sessions. `.chezmoidata/agents.yaml` declares Claude at `opus[1m]` with `claude-opus-5` and `claude-fable-5-1` effort levels, declares Codex at `gpt-5.6-luna` with `model_reasoning_effort: max`, and declares nothing for Antigravity (`agy.settings` is `{}`). The operator additionally runs `gpt-6-astra` at low effort and Gemini 3.8 Flash. R15 makes the prose independent of both lists, so neither has to be reconciled here.
- `AGENTS.md:67` describes an unrelated tool's model roster and is not the source of truth for these three harnesses. It is not edited by this plan.
- The vendor guidance cited above is current as of 2026-09-09 at the URLs recorded there. It is guidance, not a hard contract; a later vendor revision is a normal edit to the same paragraph and its fixture.
- Rendering all three wrappers under the CI recipe is available locally, because `.ci/test-agent-instructions.sh` already does exactly that.

### Sequencing

U1 and U2 both edit the template and can land together. U3 must land in the same commit as U2, because U2 alone fails the peer-render diff. U4 is independent of the gate but describes it, so it lands with U3.

## Implementation Units

### U1. Shared skills-and-precedence section

**Goal:** The core directs every agent to open the covering skill before acting, and says how disagreeing rules compose.

**Requirements:** R1, R2, R3, R4, R14.

**Files:** `.chezmoitemplates/agents-instructions.tmpl`.

**Approach:** Insert a new `## Skills and instruction precedence` section between the file header paragraph and `## Writing and language`. Write it as two paragraphs in the file's existing RFC 2119 voice.

The first paragraph carries the skills rule. Scope it to tool, platform, and repository-procedure skills. The trigger is the next action touching a tool, platform, or repository procedure a skill description names: when one matches, MUST open the most specific covering skill before that action and follow it in place of improvised steps; a task with no match proceeds without opening a skill; a further skill is opened only when a concrete step requires it; a skill the user names by name is always opened. State the two boundaries in the same paragraph — opening a skill grants no authority the core withholds, and this rule creates no mandatory workflow routing, so `## Routing and mirrors` keeps deciding between workflows. Leave the existing `orchestration` sentence in `## Routing and mirrors` unchanged; the new rule is general and that one is the dispatch-specific case.

The second paragraph carries precedence as composition (KTD5). A repository supplement may add or tighten a rule and may not remove one; where it tightens, the tighter rule governs. A skill's own instructions and the harness's defaults and automatic reminders yield to both. An agent resolves a conflict by this rule rather than trying to satisfy both sides. Close with the carve-out: the core's secrets, destructive-action, and dispatch-routing prohibitions are outside this rule and bind wherever the conflicting instruction comes from, including the active conversation. Where the paragraph names an example of a standing local exception, use OS-neutral wording — "the executable-selection rule, the `lfg` autopilot override" — because the `orca-ide` rule itself sits behind an OS gate and would be absent from the non-Linux render (R14).

**Test scenarios:**
- Render the Claude wrapper under the CI recipe; the section heading and both paragraphs are present.
- Render all three wrappers; the section is byte-identical in all three.
- Render under `darwin`; every rule the new section names is present in that render, and the section does not mention `orca-ide`.
- The `orchestration` dispatch sentence and the `Do not add mandatory ce-work/ce-debug routing here` sentence are unchanged in the diff.
- The rendered file contains no second statement of the executable-selection rule.

**Verification:** `.ci/test-agent-instructions.sh` passes once U3 has landed.

### U2. Per-harness model-tuning paragraphs

**Goal:** Each harness receives one `This harness runs ` paragraph tuned to its model family, and no other harness's.

**Requirements:** R5, R6, R7, R8, R9, R15, R16.

**Files:** `.chezmoitemplates/agents-instructions.tmpl`.

**Approach:** Add a new `## Harness and model tuning` section after the `A script MAY perform a purely mechanical change` paragraph that closes `## File edits and native tools`. Inside it, add a second `{{ if eq .harness ... }}` gate in the same shape as the existing harness gate at lines 43-49 — three branches on `.harness`, not the two-branch `.ctx.chezmoi.os` gate at lines 23-27. Each paragraph is a single line, starts with the literal `This harness runs `, names a family and no model id (R15), and is at most six sentences (R16).

Claude: names the Anthropic Claude family; states that these models verify and self-correct without being told, so no re-check pass is added beyond one an instruction or acceptance criterion already names; deliver the requested scope and say so in a sentence rather than quietly widening or narrowing it; lead with the outcome and match a written document's length to its substance; one sentence before the first tool call, then an update only on a finding or a change of direction; correct an earlier statement only when the error changes the user's code, conclusions, or decisions.

Codex: names the OpenAI Codex family; states that these models follow the smallest sufficient instruction set and degrade on padded or contradictory guidance, so a conflict is resolved by the precedence rule rather than by satisfying both; reasoning effort is read from configuration and never simulated by asking for more thinking in prose; state the goal, the boundary, and the definition of done before the first tool call; batch independent reads rather than issuing them one at a time; calibrate verification to the risk of the change, and never invent an identifier, version, price, or path.

Antigravity: names the Google Gemini Flash family; states that the model follows a direct instruction literally and answers tersely, so ask for the elaboration you want instead of assuming it; omit chain-of-thought scaffolding, role framing, and repeated restatement, which were workarounds for older Gemini versions and degrade this one. The two authoring clauses are addressed to what the agent writes, not to what it reads: in a brief or prompt the agent composes for a Gemini-family worker, put the long context first and the instruction last, and leave sampling parameters and thinking level to that worker's configuration rather than asking for them in prose.

Match the existing gate's whitespace control (`{{ if ... -}}`, `{{- else if ... -}}`, `{{- end }}`) so the rendered blank lines match the file's shape.

**Test scenarios:**
- The Claude render contains the Claude-family paragraph and neither peer paragraph.
- The Codex render contains the Codex-family paragraph and neither peer paragraph.
- The Antigravity render contains the Gemini-Flash-family paragraph and neither peer paragraph.
- Each render contains exactly one line starting with `This harness runs `.
- No `This harness runs ` line contains a model id or a point release.
- Each `This harness runs ` line is six sentences or fewer.
- Rendering under `darwin` produces the same harness paragraphs as under `linux`.

**Verification:** The three renders satisfy the scenarios above. The full gate passes only after U3 lands, because U2 alone fails the peer-render diff.

### U3. Widen the render gate and add harness-line fixtures

**Goal:** The gate compares the new paragraphs against a committed expectation instead of stripping them unchecked.

**Requirements:** R10, R11, R12.

**Files:** `.ci/test-agent-instructions.sh`, `.ci/fixtures/harness-runs-claude.txt`, `.ci/fixtures/harness-runs-codex.txt`, `.ci/fixtures/harness-runs-agy.txt`.

**Approach:** Change `strip_harness_paragraph` to `grep -vE '^This harness (is|runs) '` (KTD2). Write each harness's rendered `This harness runs ` line to a fixture file under `.ci/fixtures/`, following the naming of files already there. In the per-harness loop, extract that render's `This harness runs ` lines, assert there is exactly one, and compare it byte-for-byte against that harness's fixture; fail with the harness id and the fixture path when they differ. Because the fixture holds the whole line, no `HARNESS_NEEDLES` row is added for the new paragraphs (KTD3) — leave the existing rows for the `This harness is ` lines untouched.

Add the U1 skills and precedence sentences to the shared `NEEDLES` list. Update the `KNOWN GAP` comment to say that the gap now covers the `This harness is ` lines only, and that `This harness runs ` lines are fixture-compared.

Do not add a `BANNED` entry: nothing is being retired.

**Test scenarios:**
- The script passes on the U1 and U2 template.
- Appending a sentence to any `This harness runs ` line without updating its fixture makes the script fail, naming that harness and its fixture path.
- Deleting a harness's `This harness runs ` branch makes the script fail on the exactly-one assertion.
- Moving the Claude tuning paragraph's text into the shared body makes the script fail with a peer-divergence message.
- Reverting U1's skills paragraph makes the script fail with a `lost rule:` message.
- Restoring `strip_harness_paragraph` to the single-prefix form makes the script fail with a peer-divergence message.
- The script still fails when an existing `This harness is ` needle is removed from the template.

**Verification:** `.ci/test-agent-instructions.sh` prints `agent instruction gates passed`.

### U4. Update the repository contract

**Goal:** `AGENTS.md` describes the widened contract, so a later editor does not reintroduce the single-prefix assumption.

**Requirements:** R13.

**Files:** `AGENTS.md`.

**Approach:** In the managed-instruction-targets paragraph, replace the clause naming only `This harness is ` with one naming both harness-gated prefixes and what each owns: `This harness is ` carries the native file tools and Claude Code's delegation carve-out; `This harness runs ` carries the model-family tuning and is compared against a committed fixture per harness. Keep the rest of the paragraph, including the `.ci/test-agent-instructions.sh` sentence, unchanged. Do not touch the unrelated model-roster paragraph at line 67.

**Test scenarios:**
- `AGENTS.md` names both prefixes and states that all three renders match outside them.
- `AGENTS.md` names the fixture comparison for the `This harness runs ` prefix.
- No other paragraph in `AGENTS.md` still asserts a single harness-gated prefix.

**Verification:** Read the rendered paragraph; confirm it matches the gate's actual strip predicate and fixture assertion.

## Verification Contract

- `.ci/test-agent-instructions.sh` — the authoritative gate. It renders all three wrappers under `linux` and `darwin`, diffs the peers after stripping both harness prefixes, compares each `This harness runs ` line against its fixture, and asserts every needle. It must print `agent instruction gates passed`.
- `.ci/test-ci-wiring.sh` — confirms the gate is still wired into `.github/workflows/ci.yml`. Run it because this change touches the gate script.
- Manual read-through, once per rendered file: confirm SC1 (no sentence contradicts another in the same file), SC2 (the skills rule names an evaluable trigger), and SC3 (each tuning paragraph is six sentences or fewer and names no model id). This is the check the automated gate cannot make.
- No `chezmoi apply`. This repository is edited as source state; deployment is a separate explicit request.

## Definition of Done

Global:

- R1 through R16 are satisfied in the committed source.
- SC1 through SC3 hold for all three rendered files.
- `.ci/test-agent-instructions.sh` and `.ci/test-ci-wiring.sh` pass.
- The diff touches only `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, `.ci/fixtures/harness-runs-*.txt`, `AGENTS.md`, and this plan.
- No existing rule in the core was reworded, reordered, or removed.
- No model or effort declaration in `.chezmoidata/agents.yaml` changed.
- No experimental or dead-end text is left in the template, the fixtures, or the gate script.

Per unit:

- U1 — the new section renders identically on all three harnesses and on both OS branches, and its sentences are asserted by shared needles.
- U2 — each harness render carries its own tuning paragraph and neither peer's, within the R15 and R16 bounds.
- U3 — each `This harness runs ` line matches its fixture byte-for-byte, and every sentence added by U1 has a shared needle.
- U4 — `AGENTS.md` names both harness-gated prefixes and the fixture comparison.
