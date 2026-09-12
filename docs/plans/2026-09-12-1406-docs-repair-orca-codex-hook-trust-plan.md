---
title: Repair Orca-Managed Codex Hook Trust Before Dispatch - Plan
type: docs
date: 2026-09-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/490
---

# Repair Orca-Managed Codex Hook Trust Before Dispatch - Plan

## Goal Capsule

- **Objective:** An agent dispatching Codex workers repairs Orca-managed Codex hook trust before dispatch on every host, and correctly diagnoses `codex-hooks-review-prompt` dispatch failures without manual intervention or hand-editing config files.
- **Means:** Add one rule paragraph to the shared `## Routing and mirrors` section of `.chezmoitemplates/agents-instructions.tmpl`, using `orca-ide agent hooks prepare-codex`, diagnosing `agentWait.reason: codex-hooks-review-prompt`, and prohibiting hand-edits to `~/.codex/config.toml`. Pin the new rule with needles in `.ci/test-agent-instructions.sh` (KTD1, KTD2).
- **Authority:** Issue #490 defines the problem, proposed change, and acceptance criteria. `.chezmoitemplates/agents-instructions.tmpl` owns the shared instruction core. `.ci/test-agent-instructions.sh` owns instruction gate assertions.
- **Stop conditions:** Stop if `.ci/test-agent-instructions.sh` fails existing fixtures or banned phrases.
- **Execution profile:** Two units, template edit plus test gate assertion, no runtime daemon.
- **Tail ownership:** The calling pipeline owns commit, push, and PR.

---

## Product Contract

### Summary

Add an instruction to the shared agent-instruction core (`.chezmoitemplates/agents-instructions.tmpl`) requiring sessions to run `orca-ide agent hooks prepare-codex` before dispatching a Codex worker. The instruction explains that `agentWait.reason: codex-hooks-review-prompt` indicates unseeded hook trust rather than a worker fault, prescribes the repair command followed by retrying the dispatch, and explicitly forbids editing `~/.codex/config.toml` trust records by hand because `chezmoi apply` owns the dotfiles-side hook records. Pin the rule in `.ci/test-agent-instructions.sh` across all four harnesses on Linux and Darwin.

### Problem Frame

During orchestration smoke tests, an Orca fan-out dispatching Codex workers can fail at the agent readiness stage with:
```text
dispatch state: failed
stage:          agent_readiness
reason:         agent_prompt_blocked
agentWait.reason: codex-hooks-review-prompt
```
In unattended or automated runs (`lfg`, background coordinators), nobody is present to answer Codex's interactive hook review prompt. The dispatch times out and fails in ~15 seconds. While `chezmoi apply` pre-seeds trust for `dotfiles-codex` hooks via `codex-hook-trust.tmpl`, Orca-managed Codex hooks belong to a separate runtime layer (`~/.codex/hooks.json`). Orca provides an idempotent repair command (`orca-ide agent hooks prepare-codex`), but no standing instruction instructs agents to run it before dispatching or when encountering this failure.

### Requirements

- R1. `.chezmoitemplates/agents-instructions.tmpl` states that before dispatching a Codex worker, the session MUST run `orca-ide agent hooks prepare-codex` once to repair Orca-managed Codex hook trust.
- R2. The instruction notes that the repair command is idempotent and silent on success.
- R3. The instruction states that `agentWait.reason: codex-hooks-review-prompt` on a failed Dispatch indicates hook trust, not a worker fault, and directs running `orca-ide agent hooks prepare-codex` and retrying the Dispatch.
- R4. The instruction explicitly prohibits editing `~/.codex/config.toml` trust records by hand, explaining that `chezmoi apply` owns the dotfiles-side hook records and manual edits cause configuration contention.
- R5. The instruction names `orca-ide`, never bare `orca`, adhering to the executable-selection rule.
- R6. The instruction is placed in `## Routing and mirrors` in the shared body, outside harness-specific conditional blocks, rendering into all four managed harnesses (`claude`, `codex`, `agy`, `omp`).
- R7. `.ci/test-agent-instructions.sh` asserts needles for the new rule across all four harnesses on Linux and Darwin.
- R8. Pre-existing test assertions, fixtures, relative paragraph anchoring (`lfg` and `workflow-required-autonomy`), and banned phrases in `.ci/test-agent-instructions.sh` continue to pass.

### Key Decisions

- **Place the rule in `## Routing and mirrors` immediately after the OS-specific executable block and before the `lfg` autonomy paragraph.** Chosen over inside `orchestration-coordinator.tmpl`: the instruction core binds every session dispatching workers across all harnesses, including those outside an active Orca coordinator payload injection. Preserves the exact 2-line distance between `lfg-autonomy` and `workflow-required-autonomy`. Governs R1, R5, R6, R8.
- **Instruction-only change without apply-time invocation in `run_after_config-codex-settings.sh.tmpl`.** As noted in issue #490's open question, `orca-ide agent hooks prepare-codex` requires a reachable Orca runtime. Invoking it during `chezmoi apply` would risk failing on hosts without Orca running. Governs R1, R4.
- **Explicit prohibition on hand-editing `~/.codex/config.toml`.** Reinforces the boundary between chezmoi-managed settings and runtime repair commands. Governs R4.

### Scope Boundaries

**In scope:**
- Add the pre-dispatch Codex hook repair rule to `.chezmoitemplates/agents-instructions.tmpl`.
- Add test needles to `.ci/test-agent-instructions.sh`.
- Run verification gates.

**Out of scope:**
- Changes to `run_after_config-codex-settings.sh.tmpl` or `codex-hook-trust.tmpl` (apply-time seeding remains unchanged).
- Changes to Orca CLI implementation or Codex hook schema.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Authored as one unwrapped paragraph using RFC 2119 terms and STE principles.** Matches the style of surrounding shared-body paragraphs in `## Routing and mirrors`. Governs R1, R2, R3, R4, R5.
- KTD2. **Shared needles in `.ci/test-agent-instructions.sh`.** Added to the `NEEDLES` heredoc in `.ci/test-agent-instructions.sh` to ensure all four harnesses verify the presence of the new rule. Governs R7, R8.

### Assumptions

- `orca-ide agent hooks prepare-codex` is supported on all hosts where Orca is available, and on non-Linux hosts `orca-ide` is resolved appropriately.
- The 2-line anchoring between `lfg-autonomy.txt` and `workflow-required-autonomy.txt` in `.ci/test-agent-instructions.sh` is preserved by placing the new paragraph before `lfg-autonomy`.

### Sequencing

U1 then U2.

---

## Implementation Units

### U1. Add Codex Hook Trust Repair Instruction to Shared Core

- **Goal:** `.chezmoitemplates/agents-instructions.tmpl` contains clear instructions to repair Codex hook trust before dispatching Codex workers and diagnose hook review prompt failures.
- **Requirements:** R1, R2, R3, R4, R5, R6. Instantiates KTD1.
- **Dependencies:** None.
- **Files:** `.chezmoitemplates/agents-instructions.tmpl`
- **Approach:**
  1. Insert a new paragraph in `## Routing and mirrors` after the OS executable block (`{{- end }}` after line 37) and before the `lfg` autonomy paragraph (`During \`lfg\` pipeline execution...`).
  2. Text:
     "Before dispatching a Codex worker, the session MUST run `orca-ide agent hooks prepare-codex` once to repair Orca-managed Codex hook trust. The repair command is idempotent and silent on success. When a dispatch fails with `agentWait.reason: codex-hooks-review-prompt`, that failure signals unseeded hook trust rather than a worker fault; run `orca-ide agent hooks prepare-codex` and retry the dispatch. MUST NOT edit `~/.codex/config.toml` trust records by hand, because `chezmoi apply` owns the dotfiles-side hook records and manual edits cause configuration contention."
- **Verification:**
  - Verify render across Linux and Darwin wrappers.
  - Verify no template syntax errors.

### U2. Update Instruction Test Gate with Needles

- **Goal:** `.ci/test-agent-instructions.sh` asserts that the new instruction is present in all harness renders.
- **Requirements:** R7, R8. Instantiates KTD2.
- **Dependencies:** U1.
- **Files:** `.ci/test-agent-instructions.sh`
- **Approach:**
  1. Add needles to the `NEEDLES` heredoc in `.ci/test-agent-instructions.sh`:
     - `Before dispatching a Codex worker, the session MUST run \`orca-ide agent hooks prepare-codex\` once to repair Orca-managed Codex hook trust.`
     - `agentWait.reason: codex-hooks-review-prompt`
     - `MUST NOT edit \`~/.codex/config.toml\` trust records by hand, because \`chezmoi apply\` owns the dotfiles-side hook records and manual edits cause configuration contention.`
  2. Run `.ci/test-agent-instructions.sh` and ensure all tests pass.
- **Verification:**
  - `.ci/test-agent-instructions.sh` exits 0 with "agent instruction gates passed".

---

## Verification Contract

| Check | Command or action | Applies to |
|---|---|---|
| Instruction gate | `.ci/test-agent-instructions.sh` | U1, U2 |
| Git diff check | `git diff --check` | U1, U2 |
| Status scope check | `git status` shows only expected files | U1, U2 |

---

## Definition of Done

- All requirements R1 through R8 are satisfied.
- `.chezmoitemplates/agents-instructions.tmpl` contains the new rule.
- `.ci/test-agent-instructions.sh` asserts the new needles and passes with exit code 0.
- No other unintended changes or warnings.
