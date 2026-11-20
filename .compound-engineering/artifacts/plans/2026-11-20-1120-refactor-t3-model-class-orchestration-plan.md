---
title: T3 Model-Class Orchestration - Plan
type: refactor
date: 2026-11-20
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# T3 Model-Class Orchestration - Plan

## Goal Capsule

- **Objective:** A T3 session on any managed harness picks a child's model by model class and routes it to a harness that can actually serve it, so Pi and OpenCode sessions, which reach Claude, GPT, and Synthetic models, delegate without ambiguity and keep working when a native harness hits its usage limit.
- **Means:** Rewrite the T3-only routing sections of the shared instruction template around model classes (KTD1, KTD3) and ship a read-only OpenCode serving-model helper (KTD2).
- **Authority:** The Product Contract defines scope. The Planning Contract defines how it is built. Existing CE delegation, review, egress, and recovery rules govern everything not changed here.
- **Execution profile:** One PR. The implementer verifies locally and hands off to the shipping workflow; no host switch is part of this work.
- **Stop conditions:** Stop if the rewrite would weaken a CE egress, allowlist, or independence check, or if OpenCode's session record no longer carries provider and model for completed assistant messages.
- **Open blockers:** None.

## Product Contract

### Summary

The model selection ladder becomes one row per model class (Claude, GPT, Synthetic) instead of one row per harness. A child runs on its class's native harness by default and falls back to an instance that offers the class only when the native harness is observed failing. Effort intent follows the class, and both Pi and OpenCode can prove which model served a session.

### Problem Frame

The T3-only instructions treat each harness as a provider: the ladder rows read `Claude`, `Codex`, and `Synthetic through pi`, and children use "the ladder of the provider the child runs on." Pi and OpenCode each offer Anthropic, OpenAI, and Synthetic models, so an agent in those harnesses cannot tell which row applies, or whether "provider" means the harness or the model vendor. The only rule for choosing a model family inside one instance covers OpenCode cross-model review peers; implementation workers, scouts, and every Pi delegation lack one. When Claude Code or Codex hits a usage limit, nothing tells the agent that Pi or OpenCode could serve the same class through their API keys.

### Key Decisions

- **Ladder rows are model classes, not harnesses.** A harness is a route, and Pi and OpenCode serve all three classes. Governs R1, R2.
- **Native harness first, other instances as fallback.** (session-settled: user-directed — chosen over current-instance-first routing: Claude Code and Codex use their own sign-in credentials, while Pi and OpenCode call Anthropic and OpenAI through `anthropic_api_key` and `openai_api_key`; other instances should absorb only native-harness failures such as usage limits.) Governs R4, R5, R6, R7, R9.
- **Synthetic without a Synthetic host goes to Pi.** (session-settled: user-approved — chosen over OpenCode: matches current behavior, and the Synthetic timing evidence was measured on Pi.) Governs R4, R6.
- **Effort intent follows the model class.** (session-settled: user-approved — chosen over harness defaults outside Codex: a GPT child should get the same reasoning intent whichever harness serves it.) Governs R8.
- **Use CE's serving-family attestation wherever it works.** (session-settled: user-directed — chosen over a new repository plugin for every harness: CE already reads Pi's session record and `PI_PROVIDER`/`PI_MODEL`.) Governs R10, R11.

Product Contract preservation: Product Contract unchanged; the Deferred to Planning questions are resolved in the Planning Contract (KTD2, KTD4, KTD5, Verification Contract).

### Requirements

**Model classes and ladder**

- R1. The T3 CE model selection table has one row per model class (Claude, GPT, Synthetic) with the current rung families unchanged: Claude Fable/Opus/Sonnet/Haiku, GPT astra/sol/terra/luna, Synthetic Kimi/Kimi Pro/GLM/GLM Flash.
- R2. A child's ladder row is chosen by the model class of the model it will run, whatever harness serves it.
- R3. The column limit (a child never runs above the delegating model's column) and the rung-substitution rules keep their current meaning, applied per model class.

**Routing**

- R4. The default route for a child is its class's native harness: Claude to Claude Code, GPT to Codex, and Synthetic to the current instance when it is Pi or OpenCode, otherwise to Pi.
- R5. A child whose route is the current instance uses the harness's native subagent tool only when that tool can carry the required model, settings, and access; otherwise it uses `delegate_task` targeting the current instance.
- R6. When the native route fails with observed evidence that it cannot run (usage or quota limit, authentication failure, disabled or missing instance, or the class missing from its catalog), the agent retries the child on the first instance in this order that offers the class and whose route has not already failed for this child: the current instance, Pi, then OpenCode.
- R7. Each fallback is reported with the failed route, the evidence, and the route used; it does not repeat a route that CE's own rules forbid retrying, such as one that reported the same quota failure twice in the session.

**Effort**

- R8. Effort intent is defined per model class (for GPT: `xhigh` for every terra child and every middle-rung implementation worker, `high` for other GPT children; Claude and Synthetic keep the harness default) and is translated into the serving harness's option (Codex `reasoningEffort`, Pi `thinking`, OpenCode `variant`), falling back to the harness default when the harness offers no matching level.

**Cross-model review peers**

- R9. CE cross-model review peers follow R4 and R6: the native harness is the default route and an instance that offers the peer family is the fallback, replacing OpenCode's current same-instance-first peer rule. An explicit CE target such as `cross_model_peer: codex` keeps the route CE defines.
- R10. On Pi, the host and peer serving family come from CE's existing attestation, which reads the Pi session record (`PI_SESSION_FILE`) and `PI_PROVIDER`/`PI_MODEL`; the instructions add no parallel Pi evidence procedure.
- R11. OpenCode gets a supported way for the agent to read the provider and model that served its session and a child's run, in a form CE's host-family attestation can consume, because CE leaves OpenCode's family `unknown`.
- R12. Missing or ambiguous serving evidence keeps today's outcome: the automatic peer route is unavailable for a host, independence is unverified for a peer, and no harness switch happens because evidence is missing.

**Consistency**

- R13. Claude Code and Codex sessions keep their current default delegation behavior; their only behavior change is the fallback route in R6.
- R14. `docs/agent-routing.md` describes the reorganized rules, and the Synthetic ladder evidence section stays as it is.

### Acceptance Examples

- AE1. Covers R2, R4. A Pi session running GLM-5.3 needs a top-rung reviewer from the Claude class. It delegates to the Claude Code instance with the newest Opus model.
- AE2. Covers R4. A Claude Code session needs a bottom-rung Synthetic scout. It delegates to Pi with the newest GLM Flash model.
- AE3. Covers R6, R7. A Codex session delegates a GPT implementation worker, and the Codex instance reports a usage limit. The failed Codex route is skipped, Pi offers GPT, so the agent retries on Pi with the newest terra model and reports the fallback.
- AE4. Covers R8. A GPT terra implementation worker that falls back to OpenCode is launched with `variant: xhigh` when the model lists it, and with OpenCode's default when it does not.
- AE5. Covers R9, R12. An OpenCode session served by Claude runs `ce-code-review`. The GPT peer goes to Codex by default. If Codex reports a usage limit, the peer runs on the current OpenCode instance with a GPT model; if the host's serving family cannot be established, the automatic peer route is unavailable and no other harness is tried.
- AE6. Covers R10. A Pi session's shell shows `PI_PROVIDER=synthetic` and `PI_MODEL=hf:zai-org/GLM-5.3-Flash`, and the session file's latest assistant message names the same model. CE attests the host family from those records without extra instructions.

### Scope Boundaries

- Rung model choices and the Synthetic ladder evidence are unchanged.
- No new harness, provider, or credential is added.
- Delegations outside CE skills keep their current model selection, except that the class-keyed ladder wording replaces the harness-keyed wording.
- Cost tracking or budget alerts for API-key fallback are not part of this work.

### Dependencies / Assumptions

- Pi 1.5.2 exports `PI_PROVIDER`, `PI_MODEL`, `PI_SESSION_FILE`, `PI_SESSION_ID`, and `PI_REASONING_LEVEL` to its bash tool, and the session file records provider and model per assistant message (observed in a T3 Pi child on 2026-11-20).
- T3 reported `executedModel: null` for that Pi child, so T3 alone does not prove what served a Pi child.

### Sources / Research

- `home/h82/agents/instructions/instructions.md.tmpl` (T3 delegation and T3 CE model selection sections, OpenCode peer block).
- `docs/agent-routing.md` (T3 delegation, OpenCode cross-model reviews, Synthetic ladder evidence).
- `home/h82/agents/pi.nix` and `home/h82/agents/opencode.nix` (Synthetic, OpenAI, and Anthropic providers and API-key credentials).
- `.compound-engineering/artifacts/plans/2026-11-20-0006-feat-opencode-t3-review-routing-plan.md` (the same-instance peer route R9 replaces).
- CE `skills/ce-code-review/references/cross-model-review.md` and `skills/ce-code-review/scripts/cross-model-adversarial-review.sh` (host-family attestation; Pi via `PI_SESSION_FILE`, `PI_PROVIDER`, `PI_MODEL`; OpenCode left `unknown`).
- `scripts/opencode-auth-sync`, `packages/agent-tools.nix`, `flake.nix` `pythonScriptCheck` (pattern for a packaged Python helper and its source-level test).
- Observed on 2026-11-20 in a T3 OpenCode child: the bash tool exports `OPENCODE_SESSION_ID`, and `~/.local/share/opencode/opencode.db` table `session_message` stores assistant rows whose JSON `data` carries `model.providerID`, `model.id`, `time.completed`, and `tokens`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **One class-keyed ladder table plus a routing table in the T3 branch.** The ladder table keeps the existing columns with rows Claude, GPT, and Synthetic; a second short table maps each class to its native route and the fallback order. Rationale: two tables keep model choice (R1-R3) separate from harness choice (R4-R7), which is the ambiguity the work removes. Governs R1, R2, R3, R4, R6.
- KTD2. **OpenCode evidence comes from a packaged read-only helper, `opencode-serving-model`, not an OpenCode plugin.** It opens `~/.local/share/opencode/opencode.db` read-only, selects the session from `OPENCODE_SESSION_ID`, a `--session` argument, or the session that owns a `--message` native message ID, and prints `providerID/modelID` of the latest completed assistant message that has token usage; `--family` prints the CE family token instead (`anthropic` maps to `claude`, `openai` to `codex`, every other provider to `unknown`). Rationale: the environment and the database already carry the evidence, a plugin would load into every OpenCode session including non-T3 ones, and a Python helper follows the repository's tested `agent-tools` pattern. Only the direct `anthropic` and `openai` providers map to a family because intermediaries such as `opencode-go` do not prove the serving vendor. Governs R11, R12.
- KTD3. **The T3 branch drops its OpenCode-only block.** Routing, review-peer, and evidence rules become one body shared by every harness's T3 render, because R9 makes the review route the same everywhere and the evidence rules name their harness inline. The `t3-opencode` receipt therefore disappears unless the implementer finds another OpenCode-only line that must stay. Governs R9, R13.
- KTD4. **Pi evidence reuses CE's documented sources inside T3.** Under T3 no CE peer worker runs, so the template tells the agent to attest a Pi host or Pi child from the same records CE's worker reads: the latest assistant message in the session's `PI_SESSION_FILE`, else `PI_PROVIDER`/`PI_MODEL`. The parent locates a child's record through the native session or message ID that T3 thread activity (`t3_thread_read`) shows for the child run, as the current OpenCode rule already does; when no such ID is visible, R12 applies and the peer's independence stays unverified. A child's own claim about its model is never evidence. Conflict call-out: the settled decision says "use CE's attestation"; inside T3 that means CE's sources and rules, not CE's script, because T3 transport replaces the worker. Governs R10, R12.
- KTD5. **Fallback triggers are terminal, observed failures only.** A child run that ended with a usage, rate, or quota limit or an authentication failure, a provider instance that `orchestrator_capabilities` reports disabled or unable to run child tasks, or a catalog without the class's model triggers R6. A T3 wait timeout, a slow child, or a review finding never does. Governs R6, R7.

### Assumptions

- OpenCode is installed on both host kinds through `home/h82/agents/opencode.nix`, so adding the helper to that module's `home.packages` makes it available wherever T3 can start an OpenCode instance.
- Python's standard `sqlite3` module can open the WAL-mode database read-only through a `mode=ro` URI while OpenCode is running.

---

## Implementation Units

### U1. OpenCode serving-model helper

**Goal:** Give agents and parents a supported command that names the provider and model that served an OpenCode session.

**Requirements:** R11, R12; KTD2.

**Dependencies:** None.

**Files:**

- `scripts/opencode-serving-model` (create)
- `tests/test_opencode_serving_model.py` (create)
- `packages/agent-tools.nix` (add `opencodeServingModel` via `pythonHelper`)
- `home/h82/agents/opencode.nix` (add the helper to `home.packages`)
- `flake.nix` and `tests/check-shards.nix` (register the `pythonScriptCheck`)

**Approach:**

1. Resolve the session from `--session`, else the session owning `--message`, else `OPENCODE_SESSION_ID`; exit non-zero with a short message when none is given.
2. Open `$HOME/.local/share/opencode/opencode.db` read-only (no path-override flag; tests set a scratch `HOME`) and select the latest `session_message` row of type `assistant` for that session whose `data` has `time.completed` and a `tokens` object.
3. Print `providerID/modelID`, or the CE family token with `--family`; exit non-zero when no such row exists or the database is missing.

**Patterns to follow:** `scripts/opencode-auth-sync` and its `tests/test_opencode_auth_sync.py`; `pythonHelper` in `packages/agent-tools.nix`.

**Test scenarios:**

- A fixture database with two completed assistant rows for the session prints the newer row's `providerID/modelID`.
- An in-progress assistant row (no `time.completed`) newer than a completed one is skipped.
- Rows from another session are ignored.
- `--message` with a child's native message ID resolves that child's session and prints its model.
- `--family` maps `anthropic` to `claude`, `openai` to `codex`, and `synthetic` or `opencode-go` to `unknown`.
- A missing session ID, missing database, or session with no completed assistant row exits non-zero with a message and no stdout.
- The database file is unchanged after a run (opened read-only).

The source-level test catches query and mapping regressions against a fixture schema copied from OpenCode 2.x; it does not catch a future OpenCode schema change, which the stop condition covers.

**Verification:** The `opencode-serving-model` script check passes, and the helper appears in the OpenCode module's materialized packages.

### U2. Class-keyed T3 routing in the instruction template

**Goal:** Replace the harness-keyed T3 delegation and model selection text with model-class routing, fallback, effort, review-peer, and evidence rules.

**Requirements:** R1-R10, R12, R13; KTD1, KTD3, KTD4, KTD5.

**Dependencies:** U1 (the template names the helper).

**Files:**

- `home/h82/agents/instructions/instructions.md.tmpl`
- `tests/agent-instructions.py` (receipt hashes)

**Approach:**

1. In `# T3 delegation`, change "same-provider" to "same-instance" for the native-tool rule (R5) and add the routing table with native routes and the fallback order (R4, R6), the KTD5 trigger list, and the reporting rule (R7).
2. Replace the `{{ if .opencode }}` peer block with shared review-peer text: native harness first, same-instance fallback, explicit CE targets keep their route, catalog-qualified `provider/model` IDs, and the CE OpenCode recipient rule (R9).
3. Replace the serving-evidence paragraph with harness-named sources: Pi per KTD4, OpenCode via `opencode-serving-model` (with `--session` or `--message` for a child located per KTD4), and R12's unavailable and unverified outcomes.
4. In `# T3 CE model selection`, make the table rows Claude, GPT, and Synthetic, key the ladder on the child's model class, and restate effort per class with the option names per harness (R8).
5. Keep the column-limit and substitution paragraphs, reworded to say "class" where they say "provider" (R3).

**Patterns to follow:** The existing T3 branch's voice and paragraph order; AGENTS.md's rule against leaking another harness's branch into a render.

**Test scenarios:**

- Every T3 render (claude, codex, pi, opencode) contains the class-keyed table and the routing table, and none contains `Synthetic through pi`.
- Covers AE5. The rendered review-peer text names native-first routing with same-instance fallback and no OpenCode-only conditional.
- The non-T3 base renders are byte-identical to before (their receipts do not change).
- Updated receipt hashes pass, and the negation, repetition, and deletion mutations still fail.

**Verification:** `agent-instructions` passes with updated receipts and unchanged base receipts.

### U3. Routing documentation

**Goal:** Keep `docs/agent-routing.md` aligned with the template, as AGENTS.md requires.

**Requirements:** R14.

**Dependencies:** U2.

**Files:**

- `docs/agent-routing.md`

**Approach:**

1. Mirror the rewritten T3 delegation and T3 CE model selection text; replace "OpenCode cross-model reviews" with a section on cross-model review peers across harnesses and the evidence sources, naming `opencode-serving-model`.
2. Leave "Synthetic ladder evidence" unchanged except for the row label if it reads "Synthetic through pi".
3. Note in "Native T3 launches" that the T3 branch is now the same for every harness, if KTD3 holds.

**Test expectation:** none -- documentation, but it is an input to the `agent-instructions` check, which U2's verification already runs.

**Verification:** markdownlint passes and `agent-instructions` passes with this file as input.

---

## Verification Contract

- `nix build --no-link .#checks.x86_64-linux.agent-instructions` and the new `.#checks.x86_64-linux.opencode-serving-model`.
- `nix build --no-link .#checkShards.<shard>` for the shard that lists the new check, plus `check-shards-guard`.
- `nix fmt -- --ci`, `git diff --check`, and `markdownlint-cli2` on changed Markdown.
- Before declaring the PR ready: the `full-ci` label with `host-checks`, `vm-checks`, `build`, and `build-darwin` green on the head commit, per AGENTS.md. Darwin outputs are deferred to CI from this Linux host.
- Live T3 behavior (actual routing decisions and fallbacks in signed-in sessions) is not established by these checks and is reported as owner verification.

---

## Definition of Done

- U1-U3 are merged in one PR with the checks above green.
- No T3 render contains a harness-keyed ladder row or an OpenCode-only routing block, and the base renders are unchanged.
- `opencode-serving-model` is installed through the OpenCode module and covered by its script check.
- No abandoned-attempt code or stale receipt remains in the diff.
