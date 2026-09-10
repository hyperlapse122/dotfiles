---
title: Workflow-Required Dispatch Autonomy - Plan
type: docs
date: 2026-09-10
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/460
---

# Workflow-Required Dispatch Autonomy - Plan

## Goal Capsule

- **Objective:** An agent running a skill the operator invoked by name completes that skill's mandatory steps without handing the operator a question they already answered, so the operator spends turns on decisions and not on confirmations.
- **Means:** One new rule paragraph in the shared body of `.chezmoitemplates/agents-instructions.tmpl`, placed beside the `lfg` autonomy paragraph and registered in that file's named-local-exception list, pinned by a verbatim fixture and needles in `.ci/test-agent-instructions.sh` (KTD1, KTD2, KTD6).
- **Authority:** The issue body owns the four questions to settle. `.chezmoitemplates/agents-instructions.tmpl` is the sole owner of the rule text. `.ci/test-agent-instructions.sh` owns its assertion.
- **Stop conditions:** Stop if an existing needle, banned phrase, or harness fixture in `.ci/test-agent-instructions.sh` fails for a reason R13 does not account for, and the fix would need the rule text weakened.
- **Execution profile:** Two units, prose plus test assertions, no runtime behavior.
- **Tail ownership:** The calling pipeline owns commit, push, and PR.

---

## Product Contract

### Summary

Add a rule to the shared agent-instruction core that settles when a workflow-required step may stop to ask. The rule states that a step a user-invoked skill declares mandatory runs without a confirming question in every run mode, that this authority reaches the skill's mandatory descendants, that it covers the step's dispatch scale, that a pre-egress disclosure is an unconditional statement, and that no spend threshold reopens the question. It names what an interactive run may still ask about, scoped so the exception cannot swallow the rule. Register it in the file's named-local-exception list, and pin it in `.ci/test-agent-instructions.sh` with a verbatim fixture matched exactly once per rendered harness.

### Problem Frame

A `/ce-brainstorm` to `ce-plan` chain reached `ce-plan`'s mandatory `ce-doc-review` step. Persona selection activated five reviewers; two of them triggered the cross-model judgment pass, which the template routes across `codex`, `claude`, and `omp`. The review became eight Orca dispatches, and the agent stopped to ask the operator whether to run five reviewers or eight. The operator had already chosen the plan at the previous handoff, and `ce-plan` states the review is mandatory.

Three template rules point in different directions and none settles the case. The autonomy override in `.chezmoitemplates/agents-instructions.tmpl` is scoped to `lfg` alone, so an interactive skill chain falls back to the harness default of asking before a costly action — by omission, not by decision. The delegation carve-out on the Claude harness line already tells the agent the dispatch "IS user-requested" and to "not stop to ask for a separate confirmation," yet the agent asked anyway: that clause is silent on the dispatch's *scale*, and it is Claude-only, so it settles neither the scale question nor the other three harnesses. `ce-doc-review`'s pre-egress disclosure obligation reads like an ask, because the template never separates a statement from a gate.

The incident is also a chain, not a single invocation. The operator invoked `/ce-brainstorm`; the step that stopped belongs to `ce-doc-review`, two skills down. Any rule that grants authority only to the skill the operator typed leaves the incident unsettled.

### Requirements

**The rule's content**

- R1. The template states that a step a user-invoked skill, command, or workflow declares mandatory is carried out without a confirming question, in interactive runs as well as unattended ones. It gives an operational test for "mandatory": a step the invoked skill's protocol, lifecycle sequence, gate, or definition of done requires, whether or not the skill uses the word.
- R11. The rule states that this authority is transitive: it reaches the mandatory steps of any skill a user-invoked skill invokes as part of its own mandatory flow, so a chain such as `ce-brainstorm` to `ce-plan` to `ce-doc-review` is covered end to end.
- R2. The rule covers the step's dispatch scale — worker count, reviewer set, and cross-model fan-out that the workflow's own rules produce — and not only the decision to delegate at all.
- R3. The rule names what an interactive run may still ask about, scoped so the exception cannot swallow the rule: an open product, design, or requirements choice the workflow leaves to the operator; an action a separate prohibition in the same file already gates; and a question the invoked skill directs *for such a choice*. It states that this exception never licenses a question confirming whether a mandatory step runs, or at what dispatch scale.
- R12. The rule states that during an `lfg` run the `lfg` autopilot governs and R3's exceptions do not apply, so the two adjacent paragraphs cannot be read as contradicting each other.
- R4. The rule settles a pre-egress disclosure as an unconditional statement the agent makes and proceeds past in the same turn. It states that the file's standing prohibitions — the secrets rules, the destructive-action rules, and the not-the-user's-repository ask-first rule — govern independently on their own terms and are not conditions that convert a disclosure into a confirmation prompt. Recipient identity and document sensitivity alone change nothing.
- R5. The rule states that no spend threshold reopens the question, and names only bounds that hold for every rendered harness: the workflow's own dispatch definitions, the per-worker deadline set before dispatch, and the run's wall-clock bound. It requires the disclosure to name the resolved dispatch count, so the operator can interrupt a fan-out they did not expect without being asked to approve it.
- R6. The rule states that it authorizes no dispatch the invoked skill does not itself define.

**Placement and precedence**

- R7. The rule sits in the shared body immediately after the `lfg` autonomy paragraph, outside every `{{ if eq .harness … }}` block, so every rendered harness receives it and an interactive run reaches it from the same place as the `lfg` override.
- R8. The rule declares its own precedence over the harness's general ask-before-ambiguous, costly, or irreversible action guidance for the step it covers.
- R13. The named-local-exception list in `## Skills and instruction precedence` gains this rule alongside the executable-selection rule and the `lfg` autopilot override, so it stays authoritative for its own subject against a repository supplement that tightens toward asking.

**Assertion**

- R9. The gate carries one needle per requirement the new paragraph covers — R1, R11, R2, R3, R12, R4, R5, and R6 — so the needle set is derived from this list rather than from a judgment about which sentences are load-bearing.
- R14. A committed fixture holds the new paragraph verbatim, and the gate asserts it matches exactly once in every harness render on `linux` and on `darwin`. A substring needle cannot catch a duplicated paragraph or an appended clause that reverses a MUST; the fixture can.
- R15. The gate pins the `lfg` autonomy paragraph the same way it pins the model-tuning line, so a load-bearing clause cannot be dropped from the paragraph this change sits beside while the gate stays green.
- R10. Every existing needle, banned phrase, and harness fixture in `.ci/test-agent-instructions.sh` still passes. The single exception is the precedence needle R13 edits, which is updated in the same commit.

### Key Decisions

- **Settle toward autonomy, scoped to workflow-required steps and their mandatory descendants.** Chosen over keeping the interactive right to confirm: the operator already authorized the step when they invoked the skill by name, and re-asking converts a mandatory step into a vote. Governs R1, R11, R2, R3, R12.
- **Disclosure is an unconditional statement; standing prohibitions are prohibitions, not gates.** Chosen over a sensitivity-or-recipient test, and over listing the prohibitions as conditions that gate a disclosure: a secrets prohibition is an absolute block that operator consent cannot lift, so describing it as something the agent may ask about would invite exactly the wrong prompt. Governs R4.
- **No spend threshold; disclose the count instead.** Chosen over a numeric fan-out cap: a workflow's own persona selection routinely produces counts a fixed cap would trip, and a cap that fires becomes the prompt this change removes. Naming the resolved count in the disclosure gives the operator the same visibility without a question. Governs R5.

### Scope Boundaries

**In scope**

- The new rule paragraph in `.chezmoitemplates/agents-instructions.tmpl`.
- The named-local-exception list in that file's `## Skills and instruction precedence` section (R13).
- Its fixture and needles in `.ci/test-agent-instructions.sh`.

**Out of scope**

- The Claude-only delegation carve-out on the `This harness is Claude Code.` line. R6 and that line's closing clause state a parallel limit; the shared-body statement is the authoritative one, and a future edit updates it first and the Claude clause only to match. Editing the Claude line now would churn a pinned needle for no behavior change.
- The `lfg` autonomy paragraph's own text. It stays scoped to `lfg`; R12 resolves the two paragraphs' relationship from the new paragraph's side, and R15 only pins the old one.
- `compound-engineering` skill files. The template is the owner; a plugin-side change would be reverted on the next plugin bump.

**Deferred to Follow-Up Work**

- Whether the `lfg` autonomy paragraph still carries unique content once the shared rule generalizes autonomy, or reduces to the new rule plus its merge-the-PR obligation. Consolidating them is a separate change with its own needle churn.

### Sources

- `.chezmoitemplates/agents-instructions.tmpl` — the `## Skills and instruction precedence` section's named-local-exception sentence, and the `## Routing and mirrors` section: the dispatch-routing rule, the shared dispatch-target recipient rule, the Orca review contract, and the `lfg` autonomy paragraph the new rule sits beside.
- `.ci/test-agent-instructions.sh` — the gate. Its header records why needles exist: the shared body's paragraphs are single unwrapped multi-thousand-character lines, so a line-granular diff reports "one changed line" whether an edit is correct or silently drops a neighbouring MUST. Its `harness-runs-<harness>.txt` fixture comparison is the pattern R14 and R15 follow.
- `AGENTS.md` — the verification contract for any template change: scratch directory, stub `op`, empty config, throwaway destination, `--source "$PWD"`.
- `STRATEGY.md` — the duplicate-knowledge metric that the Scope Boundaries ownership note serves.
- https://github.com/hyperlapse122/dotfiles/issues/460 — the four questions and the incident that raised them.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **One new shared-body paragraph, after the `lfg` autonomy paragraph.** The gap is harness-general and fires outside `lfg`, so neither the `lfg` paragraph nor the Claude-only carve-out can hold it. The shared body reaches all four rendered harnesses. Governs R7.
- KTD2. **Register the rule in the named-local-exception list, and update its needle in the same commit.** That list is what keeps a rule in this file authoritative against a repository supplement that tightens. Leaving the new rule off it would let a supplement re-impose the confirming question the rule removes. The gate's own convention for pinned prose is to update the assertion alongside the text. Governs R13, R10.
- KTD3. **Derive the needle set from the requirement list.** "Load-bearing sentence" is a judgment two implementers resolve differently, which leaves a MUST unpinned. One needle per covered requirement is mechanically checkable. Governs R9.
- KTD4. **State the rule as RFC 2119 MUST / MUST NOT text.** The file declares that RFC 2119 terms are read literally, and the surrounding dispatch rules already use them; a SHOULD here would leave the same ambiguity the issue reports. Governs R1, R11, R2, R3, R4, R5, R6, R12.
- KTD6. **Assert the paragraph with a verbatim fixture, not needles alone.** `grep -F` proves a fragment appears somewhere: it survives a duplicated paragraph and an appended clause that reverses the MUST it follows. A fixture compared whole, matched exactly once per render, catches both. The needles from KTD3 stay as the per-requirement diagnostic that names *which* rule was lost. Governs R14, R15.

### Assumptions

No operator confirmed the settlement, so the four answers below are the plan's own bets. Each is recorded here rather than left implicit.

- The autonomy override generalizes to any workflow-required step in a user-invoked skill chain, transitively through mandatory descendants, and interactive mode does not keep a right to confirm that step.
- It covers dispatch scale, not only the decision to delegate.
- A pre-egress disclosure is an unconditional statement; the file's standing prohibitions bind on their own terms and never become confirmation prompts.
- No spend threshold applies. The existing per-dispatch bounds cap cost, and the disclosure's dispatch count gives the operator visibility without a question.

### Sequencing

U1 then U2. U2's fixture and needles quote U1's authored text verbatim, so the text must exist first.

---

## Implementation Units

### U1. Add the workflow-required-step rule to the instruction core

- **Goal:** The shared agent-instruction core states when a workflow-required step may stop to ask, reaches every rendered harness, and holds its authority against a tightening repository supplement.
- **Requirements:** R1, R11, R2, R3, R12, R4, R5, R6, R7, R8, R13. Instantiates KTD1, KTD2, KTD4.
- **Dependencies:** none.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`
- **Approach:**
  1. Insert one new paragraph immediately after the paragraph beginning `During \`lfg\` pipeline execution, MUST run fully autonomously`, inside `## Routing and mirrors` and outside every `{{ if eq .harness … }}` block.
  2. Write it as one unwrapped line, matching the surrounding paragraphs' shape.
  3. Cover the content requirements in this order: R1 (the rule and the test for "mandatory"), R11 (transitive through mandatory descendants), R2 (scale), R3 (the scoped interactive exception and what it never licenses), R12 (`lfg` governs inside an `lfg` run), R4 (disclosure), R5 (no threshold, the bounds that hold everywhere, the count in the disclosure), R6 (no new authority).
  4. State the precedence clause (R8) inside the paragraph, describing the harness default in the same terms the `lfg` paragraph uses — the general ask-before-ambiguous, costly, or irreversible action guidance.
  5. For R5, name only bounds present in the shared body or in every harness's flow: the workflow's own dispatch definitions, the per-worker deadline set before dispatch, and the run's wall-clock bound. Do **not** name the `omp`-by-default Implementation-Unit rule — it lives inside the `{{ if eq .harness "claude" }}` block and the gate's leak assertion fails if it reaches a peer render. The shared body's own recipient rule is the dispatch-target sentence beginning `Dispatch targets are the \`claude\`, \`codex\`, and \`omp\` agents`; cite that one if a recipient rule is needed at all.
  6. Add the new rule to the named-local-exception list in `## Skills and instruction precedence` (R13), extending the existing pair rather than replacing it.
  7. Change no other line. The `lfg` paragraph and the Claude delegation carve-out stay byte-identical.
- **Patterns to follow:** the sibling shared-body paragraphs in `## Routing and mirrors` — the one beginning `This rule fixes the path a dispatch takes` and the one beginning `An \`lfg\` run's cross-model stages are workflow-required work`. One unwrapped line, RFC 2119 verbs, a rule then its reason, no bullet lists.
- **Test scenarios:**
  - Render `dot_claude/readonly_CLAUDE.md.tmpl` under the AGENTS.md verification recipe: the new paragraph appears exactly once.
  - Render the three peer wrappers (`dot_gemini/readonly_AGENTS.md.tmpl`, `dot_codex/readonly_AGENTS.md.tmpl`, `dot_omp/private_agent/private_readonly_AGENTS.md.tmpl`): the new paragraph appears exactly once in each, with identical text.
  - Render on `darwin` as well as `linux`: the two renders differ only in the executable-selection rule, so the new paragraph is not OS-conditional.
  - Grep every render for the string `dispatch each Unit worker to \`omp\` by default`: it appears in the Claude render only, proving step 5 did not leak the Claude-only bound into the shared paragraph.
  - `git diff --word-diff` on `.chezmoitemplates/agents-instructions.tmpl` shows added words only in the precedence sentence, and one added paragraph — no deletion or reflow of a neighbouring clause.
- **Verification:** `.ci/test-agent-instructions.sh` passes with every pre-existing needle and banned phrase unchanged except the precedence needle U2 updates, proving no neighbouring MUST was dropped.

### U2. Pin the new rule and its neighbour in the instruction gate

- **Goal:** A future edit cannot silently drop, duplicate, or reverse a load-bearing sentence of the new rule, or of the `lfg` paragraph beside it.
- **Requirements:** R9, R14, R15, R10. Instantiates KTD3, KTD6, KTD2.
- **Dependencies:** U1.
- **Files:** `.ci/test-agent-instructions.sh`, `.ci/fixtures/agent-instructions/workflow-required-autonomy.txt`, `.ci/fixtures/agent-instructions/lfg-autonomy.txt`
- **Approach:**
  1. Write the new paragraph verbatim into `.ci/fixtures/agent-instructions/workflow-required-autonomy.txt`, and the existing `lfg` autonomy paragraph verbatim into `.ci/fixtures/agent-instructions/lfg-autonomy.txt`.
  2. In the per-harness loop, for both the `linux` and the `darwin` render, assert each fixture's line is present **exactly once**. Follow the shape the existing `harness-runs-<harness>.txt` check uses: extract the matching line, require a count of one, then `diff` it against the fixture.
  3. Add one needle per covered requirement (R1, R11, R2, R3, R12, R4, R5, R6) to the shared-body `NEEDLES` heredoc, quoting each verbatim from the authored text including backticks and em dashes so `grep -F` matches. These name which rule was lost when the fixture check fails.
  4. Update the existing precedence needle to the sentence R13 rewrote. Change no other needle.
  5. Register both new fixture paths with the gate's `require_file` calls so a missing fixture fails loudly rather than skipping the check.
  6. Add no banned phrase; this change retires no rule.
- **Patterns to follow:** the `runs_fixture` block already in `.ci/test-agent-instructions.sh` — `require_file`, extract the line, assert a count of one, `diff -q` against the fixture, and fail with a message naming the fixture path. Its comment already states the contract R14 extends: "Editing that prose means updating its fixture in the same commit."
- **Test scenarios:**
  - `.ci/test-agent-instructions.sh` passes on the working tree.
  - Delete one sentence of the new paragraph from the template and rerun: the gate fails, naming both the fixture mismatch and the needle for that requirement. Restore afterward.
  - Append a clause to the new paragraph that reverses one of its MUSTs and rerun: the fixture check fails even though every needle still matches. Restore afterward.
  - Duplicate the new paragraph in the template and rerun: the exactly-once assertion fails. Restore afterward.
  - Move the new paragraph inside the `{{ if eq .harness "claude" }}` block and rerun: the gate fails, because the peer harnesses lose the rule. Restore afterward.
  - Delete a clause from the `lfg` autonomy paragraph and rerun: the `lfg` fixture check fails. Restore afterward.
- **Verification:** the gate fails on each injected regression and passes on the restored tree.

---

## Verification Contract

| Check | Command or action | Applies to |
|---|---|---|
| Instruction gate | `.ci/test-agent-instructions.sh` | U1, U2 |
| Render gate | Render all four wrappers with `chezmoi execute-template --source "$PWD"`, the stub `op`, an empty config, and a throwaway destination under the scratch directory, per `AGENTS.md` | U1 |
| Exactly-once | Both new fixtures match exactly one line in every harness render, on `linux` and on `darwin` | U1, U2 |
| Claude-only leak | The `omp`-by-default Implementation-Unit sentence appears in the Claude render only | U1 |
| OS parity | Render each wrapper for `linux` and `darwin`; the diff is confined to the executable-selection rule | U1 |
| Whitespace | `git diff --check` | U1, U2 |
| Scope | `git status` and the diff show only `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, the two new fixture files, and this plan | U1, U2 |

Never render against `$HOME`, and never invoke the real `op`. Use `.ci/lib/render-gate-helpers.sh` `render()` rather than a hand-rolled invocation.

---

## Definition of Done

- R1 through R15 are satisfied.
- `.ci/test-agent-instructions.sh` passes, with the eight new needles present, both new fixtures registered and matched exactly once per harness per OS, and every pre-existing needle, banned phrase, and harness fixture unchanged except the precedence needle R13 required.
- All four harness wrappers render the new paragraph exactly once, with identical text, on `linux` and on `darwin`.
- The `lfg` autonomy paragraph and the Claude delegation carve-out are byte-identical to `HEAD`. The `## Skills and instruction precedence` sentence differs from `HEAD` only by the added named exception.
- The diff touches only `.chezmoitemplates/agents-instructions.tmpl`, `.ci/test-agent-instructions.sh`, the two new fixture files, and this plan.
- No `chezmoi apply` ran against the live `$HOME`.
- No abandoned experimental text remains in the template, the gate, or the fixtures.
