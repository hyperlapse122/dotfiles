---
title: Reduce Agent-Added Verification and Constraints - Plan
type: chore
date: 2026-11-14
topic: reduce-agent-verification
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Reduce Agent-Added Verification and Constraints - Plan

## Goal Capsule

- **Objective:** Agents on every managed harness finish the requested work, confirm it once at the narrowest scope that shows it works, and stop, without adding verification, code, requirements, or constraints nobody asked for.
- **Means:** Add one scope section to the shared user instructions and trim the existing shared and T3 Code instructions to the same standard.
- **Authority:** The owner confirmed this scope in the brainstorm session. Repository instructions govern how the change is verified and shipped.
- **Execution profile:** Three units in one PR. The LFG controller implements, reviews, and publishes it; delegated workers run on Codex, as the owner asked.
- **Stop conditions:** A settled decision proves infeasible, or a rule that R9 protects cannot keep its substance after rewording.
- **Open blockers:** None.

---

## Product Contract

### Summary

Add a short common section to the shared instruction template that states where a task ends and what an agent does with extra ideas.
Rewrite the existing shared and T3 Code instructions so they demand verification and caution only where a reason still holds.
File two follow-up issues for the harnesses whose T3 Code sessions never receive the T3 instructions.

### Problem Frame

Work delegated to GPT-family models, and to a lesser degree other models, takes hours where it should take minutes.
In the `reepie-app` repository, threads merged 138 changed files with 25,411 added lines in under a day, and most of it was verifiers, test drivers, and evidence documents.
One verification pass there takes 71 minutes, and each change went through about ten reviewer children.
Part of that cost comes from project rules and slow tests, which that repository is fixing separately.
The rest comes from agents adding checks, guards, requirements, and delegation constraints on their own, and from instruction files that accumulate verification demands and cautions over time.

Provider guidance and one study point the same way.
Anthropic's guides for Opus 5 and Fable 5.2 say to remove verification instructions instead of rewriting them, and report that cautions pile up in instruction files, some written by the model itself.
OpenAI's GPT-5 guide reports that forceful thoroughness wording makes the model overuse tools on small tasks, and that contradictory instructions cost reasoning tokens.
A study of repository context files (arXiv 2602.11988) found agents follow them closely, which raised testing, exploration, and inference cost by over 20% without a general gain in task success.

### Key Decisions

- **The new section applies to all five harnesses.** (session-settled: user-directed — chosen over a Codex-only branch: the owner wants one rule for every model, and the supervising Claude thread also wrote over-constrained briefs.) Governs R1.
- **The section restrains only what an agent adds on its own.** (session-settled: user-directed — chosen over scaling skill-prescribed and project-prescribed procedures to change size: a user-level rule that outranks every repository's explicit rules would also loosen repositories that are strict on purpose.) Governs R2.
- **Rules read as completion criteria, with absolute wording kept for real invariants.** The provider guides report that prohibitions and forceful wording are over-applied, while stop conditions reduce extra work. Governs R3, R4, R8.
- **Existing instructions are trimmed in the same change.** The owner added this after the research showed that removing verification demands does more than adding a rule against them. Governs R7, R8, R9.
- **Rules that record a measured failure keep their substance.** Removing them would bring the failure back. Governs R9.

### Requirements

**New scope section**

- R1. The shared instruction template carries one new common section, rendered for Claude Code, Codex, Antigravity, Grok, and Pi.
- R2. The section limits what the agent adds on its own initiative; procedures the user, a project's instructions, or a skill state explicitly still apply in full.
- R3. The section states the completion standard: the change is confirmed once at the narrowest scope that shows it works, and a check that already passed is not rerun on unchanged code.
- R4. The section covers four behaviors in concrete terms: running verification beyond that standard, adding code, tests, or guards outside the request, inflating plans and documents with requirements nobody asked for, and inventing constraints in delegation briefs.
- R5. An idea outside the request, such as an extra test, guard, or verification step, is not carried out; the agent offers it in one line of its final report.
- R6. The agent does not add verification rules or cautions to instruction files, plans, or project documents unless asked.

**Trimming existing instructions**

- R7. Sentences in the shared instructions and the T3 Code instructions that demand verification or caution are removed when their reason no longer holds.
- R8. Rules that stay are written as completion criteria or scoped statements with their reason; absolute wording stays only on real invariants such as destructive or irreversible actions, secrets, and shared resources owned by other work.
- R9. Rules that record a measured or documented failure keep their substance and may only be shortened: the T3 delegation routing, the handling of Codex children that return early, the inline-fallback rule, the wait for slow commands, the temporary-resource cleanup, and the writing-skill rules.

**Safety carve-out**

- R10. Confirmation before destructive or irreversible actions and protection of secrets and stored data are named in the new section as outside its reach.

**Follow-up issues**

- R11. One GitHub issue is filed for delivering the T3 Code instructions to Grok sessions in T3 Code.
- R12. One GitHub issue is filed for delivering the T3 Code instructions to Antigravity sessions in T3 Code.

### Acceptance Examples

- AE1. **Covers R2, R3.** Given a repository whose instructions require the full check suite before a push, when an agent changes one file there, then it runs the full suite as that repository says and adds no further checks of its own.
- AE2. **Covers R3, R5.** Given a one-line fix in a repository with no stated verification rule, when the narrowest relevant check passes once, then the agent stops and lists any wider test it considered as one line in its report.
- AE3. **Covers R4.** Given an orchestrator delegating a small task, when it writes the brief, then the brief holds the goal, the completion standard, and real invariants, and does not restate rules the child already receives or invent new prohibitions.
- AE4. **Covers R6.** Given an agent that hits a failure during a task, when it finishes, then it does not append a new caution to an instruction file unless the user asked for one.
- AE5. **Covers R10.** Given a task that requires deleting data, when the agent reaches that step, then it still asks for confirmation.

### Scope Boundaries

- The model-selection ladder and reasoning-effort rules in the T3 Code instructions are unchanged. The `xhigh` effort for Codex implementation workers may add to run time, but it was set from measurement and needs its own review.
- This repository's `AGENTS.md`, Compound Engineering skills and their review fan-out, and other repositories' instruction files are unchanged.
- No check or measurement of the new section's effect on agent behavior is built. The owner judges it from later threads and adjusts the wording.
- Implementing T3 instruction delivery for Grok and Antigravity is deferred to the issues from R11 and R12.

### Dependencies / Assumptions

- Any change to the shared template must update the receipt hashes in `tests/agent-instructions.py` and keep `docs/agent-routing.md` aligned, and a change to the T3 delegation or model-selection sections must update `docs/agent-routing.md` in the same change (`AGENTS.md`).
- T3 Code's `grok` and `antigravity` drivers accept no per-launch prompt option, so their sessions receive only the shared instructions until R11 and R12 are resolved (`AGENTS.md`).
- No source measured an instruction of this kind on GPT 5.x Codex models. The provider sample prompts were tested on their own models, so the effect on Codex is an assumption.

### Sources / Research

- `home/h82/agents/instructions/instructions.md.tmpl`: the shared template; the T3 branch and the common branch are both in scope.
- `.compound-engineering/artifacts/plans/2026-11-13-1629-feat-modern-web-guidance-plan.md`: the most recent change that added a common section to the template.
- `.compound-engineering/artifacts/solutions/best-practices/codex-child-give-up-rate-by-reasoning-effort.md` and `.compound-engineering/artifacts/solutions/integration-issues/slow-command-wait-needs-harness-exit-record-not-pgrep-or-monitor.md`: measured failures behind rules that R9 protects.
- [Prompting Claude Opus 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5): remove verification instructions; scope sample prompt; subagents not used to re-check own work.
- [Prompting Claude Fable 5.2](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-2): caution that piles up in memory and instruction files; "never" read as absolute.
- [GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide): stop criteria and tool budgets; forceful thoroughness wording backfires.
- [Codex Prompting Guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide): plans exclude tests and refactors not done now; optional work is labelled as next steps.
- [Evaluating AGENTS.md (arXiv 2602.11988)](https://arxiv.org/abs/2602.11988): context files are followed closely and raise cost by over 20% without a general gain in success.

---

## Planning Contract

Product Contract preservation: Product Contract unchanged. The question deferred to planning is answered by KTD2 and KTD3.

### Key Technical Decisions

- KTD1. **The new section is one unconditional block in the template's common branch.** The common branch already renders identically for all five harnesses, so no harness variable is needed, and the T3 branch stays free of it because T3 sessions also load the baseline file. Implements R1.
- KTD2. **The audit found nothing to delete outright; trimming means removing duplicates and rewording.** Every verification or caution sentence in the template traces to a documented failure or protects shared resources, so R7 applies to the duplicated statements listed in KTD3 and R8 to the rest.
- KTD3. **Per-rule disposition for the existing text.** Rules not listed stay as written.

| Location | Current text | Disposition |
| --- | --- | --- |
| T3 delegation, paragraphs 1 and 5 | "these sessions disable that tool on purpose" stated twice | Keep one statement, in paragraph 5 where the fallback rule uses it |
| T3 delegation, paragraph 2 | A brief carries "the required context, accessible workspace/artifact paths, and this routing policy" | Keep; add that the brief states the goal and the completion standard and adds no prohibition the task does not need |
| T3 delegation, paragraph 3 | Wait for slow commands; evidence this machine cannot produce is deferred to CI | Keep the substance per R9; no rewording needed |
| T3 delegation, paragraph 4 | "Retain substantive scope, integration, and verification checks" | Reword as a scoped statement: the checks a CE skill prescribes still apply under T3 transport |
| T3 delegation, paragraph 6 | "do not add a separate failure policy or approval step" | Keep; it already limits agent-added process |
| T3 CE model selection | Whole section | Unchanged, per Scope Boundaries |
| Temporary containers, six bullets | Cleanup, protection of other tasks' resources, zero-volume check, disk-space reporting | Keep every obligation per R9; shorten, and state each once |
| Container runtime, NixOS | "Verify zero owned volumes and report disk-space reclamation separately" | Remove; the common section above already states both |
| Container runtime, Darwin | Check the `container` version before relying on an operation | Keep; it is already scoped to a required operation |
| Web development skills, Writing skills | Whole sections | Unchanged |

- KTD4. **Draft wording for the new section.** The implementer finalizes it through the writing skill, keeps every clause below, and places it first in the common branch so it frames the sections after it.

```markdown
# Scope and verification

Deliver what was asked, at the scope intended. A task is done when the change is in place and one check at the narrowest scope that shows it works has passed.

What the user, the project's instructions, or a loaded skill asks for still applies in full, including checks they say to repeat, content they require in a plan, and reviews they dispatch. The rest of this section limits only what you add on your own initiative:

- One narrow check is enough. Do not rerun a check that passed while the code is unchanged.
- Keep the change to the request. Offer a test, guard, fallback, refactor, or extra verification step that nobody asked for in one line of the final report instead of doing it.
- In a plan or document, leave out requirements, verification steps, and constraints that the request does not need.
- A delegation brief states the goal, the completion standard, and the invariants that apply to that task. Leave out rules the child already receives, and do not start a child only to re-check your work.
- Do not add a verification rule or caution to an instruction file, plan, or project document.

Confirmation before destructive or irreversible actions, and the protection of secrets and stored data, are unchanged.
```

- KTD5. **`docs/agent-routing.md` changes with the template.** Its opening paragraph names the shared rules and gains the scope rule, and its `T3 delegation` section mirrors the template text and takes the same edits (`AGENTS.md`).

### Risks

- A model may read "one narrow check" as leave to skip a project's required checks. The second paragraph of KTD4 states the precedence for every bullet after it, and AE1 covers it.
- The section may not change Codex behavior at all; no source measured it. The owner accepted judging it from later threads.

---

## Implementation Units

### U1. Add the scope section to the common branch

- **Goal:** Every harness's baseline instruction file carries the new section.
- **Requirements:** R1, R2, R3, R4, R5, R6, R10; KTD1, KTD4.
- **Dependencies:** None.
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `tests/agent-instructions.py`, `docs/agent-routing.md`.
- **Approach:**
  1. Insert the section from KTD4 at the top of the common branch.
  2. Add the scope rule to the opening paragraph of `docs/agent-routing.md`.
  3. Update the `darwin` and `nixos` receipts after U2's common-branch edits, so each receipt changes once.
- **Patterns to follow:** The `Web development skills` section added by `.compound-engineering/artifacts/plans/2026-11-13-1629-feat-modern-web-guidance-plan.md`.
- **Test scenarios:**
  - Covers AE1. The rendered baseline for each harness contains the precedence clause and the completion standard; the existing receipt check proves all five renders are byte-identical to the reviewed text.
  - The T3 render does not contain the `Scope and verification` heading.
- **Verification:** The `agent-instructions` and `t3code-traits` checks pass with the new `darwin` and `nixos` receipts.

### U2. Trim the existing shared and T3 Code instructions

- **Goal:** The existing text states each obligation once, in scoped wording, with no protected rule weakened.
- **Requirements:** R7, R8, R9; KTD2, KTD3, KTD5.
- **Dependencies:** U1 (same files; receipts are updated once both are in).
- **Files:** `home/h82/agents/instructions/instructions.md.tmpl`, `tests/agent-instructions.py`, `docs/agent-routing.md`.
- **Approach:**
  1. Apply each row of KTD3 to the template.
  2. Mirror the T3 branch edits in the `T3 delegation` section of `docs/agent-routing.md`.
  3. Update the `t3`, `darwin`, and `nixos` receipts from the final renders.
- **Execution note:** Before rewording a protected rule, read the learning that introduced it and confirm the reworded sentence still states the failure it prevents.
- **Patterns to follow:** `.compound-engineering/artifacts/solutions/best-practices/substring-sentence-check-passes-a-negated-instruction.md` explains why the receipts cover the whole body.
- **Test scenarios:**
  - The T3 render still contains the `T3 delegation` and `T3 CE model selection` headings and no `Writing skills` heading, which the existing checks assert.
  - Each R9 rule named in the Product Contract is still present in the final render: wait for slow commands, evidence deferred to CI, inline fallback only after `delegate_task` is unavailable, cleanup of task-owned resources, and the writing-skill rules.
  - The NixOS render states the zero-volume check exactly once.
- **Verification:** The `agent-instructions` and `t3code-traits` checks pass, and the final diff of the template shows no protected obligation removed.

### U3. File the two follow-up issues

- **Goal:** The delivery gap for Grok and Antigravity T3 Code sessions is tracked.
- **Requirements:** R11, R12.
- **Dependencies:** None.
- **Files:** None.
- **Approach:** File one issue per harness in `hyperlapse122/dotfiles`. Each states the gap, the driver limitation recorded in `AGENTS.md` and `docs/agent-routing.md`, and the outcome wanted, without prescribing a mechanism.
- **Test scenarios:** Test expectation: none -- the unit creates two tracker issues and changes no file.
- **Verification:** Both issue URLs are recorded in the PR body.

---

## Verification Contract

| Check | Applies to | Done signal |
| --- | --- | --- |
| `nix build --no-link .#checks.x86_64-linux.agent-instructions` | U1, U2 | Passes with the updated receipts |
| `nix build --no-link .#checks.x86_64-linux.t3code-traits` | U1, U2 | Passes |
| `markdownlint-cli2` on changed Markdown, `nix fmt -- --ci`, `git diff --check` | U1, U2 | Clean |
| CI on the PR head, with the `full-ci` label because the template changes every Home Manager generation | PR | Required jobs succeed, as `AGENTS.md` defines |

Darwin evidence this Linux host cannot produce is deferred to CI.

---

## Definition of Done

- R1 through R12 hold, and the five baseline renders plus the T3 render match their receipts.
- `docs/agent-routing.md` matches the template.
- Both follow-up issues exist and the PR body links them.
- No experimental wording or abandoned edit remains in the diff.
