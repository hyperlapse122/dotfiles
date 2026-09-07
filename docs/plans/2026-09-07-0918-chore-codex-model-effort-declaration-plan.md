---
title: Codex Model and Effort Declaration - Plan
type: chore
date: 2026-09-07
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Codex Model and Effort Declaration - Plan

## Goal Capsule

- **Objective:** A Codex run on a managed host uses the model and reasoning effort the operator chose, and a `chezmoi apply` restores that choice instead of reverting it.
- **Means:** Declare `model` and `model_reasoning_effort` as leaves of `agents.codex.settings` (KTD1).
- **Authority:** This plan, then the repository supplement `AGENTS.md`, then the live `~/.codex/config.toml` values as the source of the two literals.
- **Execution profile:** Small data change plus its guard test. No apply to the live `$HOME`.
- **Stop conditions:** The live config values differ from `gpt-6-astra` / `medium` at implementation time; the render-time validator rejects the `model` leaf.
- **Tail ownership:** The caller owns commit, push, and PR.

---

## Product Contract

### Summary

Declare the Codex model and reasoning effort in the dotfiles source so the settings reconciler asserts them on every apply. The declaration takes the values already set on this host: `model = "gpt-6-astra"` and `model_reasoning_effort = "medium"`. The guard test and the data comment that both record the old posture move with it.

### Problem Frame

`agents.codex.settings` declares the headless posture but leaves `model` undeclared and pins `model_reasoning_effort` to `high`. The live `~/.codex/config.toml` on this host carries `model = "gpt-6-astra"` and `model_reasoning_effort = "medium"`. The reconciler asserts declared leaves on every apply, so the next apply would overwrite the operator's effort choice with `high`, and the model choice is not restored at all if Codex or a reinstall drops it.

### Key Decisions

- **Declare the model rather than tracking the CLI default.** The current comment states `model` is undeclared so the CLI default tracks the installed release. Declaring it makes the operator's model choice authoritative and survivable across applies. Governs R1, R3. (session-settled: user-directed — chosen over leaving `model` undeclared and effort at `high`: the user asked for the source to match this host's chosen values.)
- **Take both literals from the live config, not from the request text.** The user flagged that the values in the request might be wrong. Governs R2.

### Requirements

**Declaration**

- R1. `agents.codex.settings` declares `model: gpt-6-astra`.
- R2. Both literals equal the values read from the live `~/.codex/config.toml` at implementation time; a mismatch stops the work and is reported.
- R3. `agents.codex.settings` declares `model_reasoning_effort: medium`.

**Consistency of the surrounding record**

- R4. The comment above `agents.codex.settings` no longer states that `model` is undeclared, and states why it now is declared.
- R5. `.ci/test-codex-settings-reconcile.sh` asserts the new posture: `model_reasoning_effort == "medium"` and `model == "gpt-6-astra"`.

### Scope Boundaries

- No change to `approval_policy`, `sandbox_mode`, or `sandbox_workspace_write.network_access`.
- No change to `.chezmoitemplates/codex-settings-validate.tmpl`. `model` is not on a security-sensitive prefix or exact-key list, so the existing grammar and allowlist accept it unchanged.
- No `chezmoi apply` against the live `$HOME`.
- No change to the Claude Code or Antigravity declarations.

### Sources

- `.chezmoidata/agents.yaml:141-163` — the `agents.codex` block and the comment that records the undeclared-model rationale.
- `.ci/test-codex-settings-reconcile.sh:112-115` — the declared-posture assertion.
- `.chezmoitemplates/codex-settings-validate.tmpl:73-75` — the security prefix, exact-key, and reviewed-path lists that `model` is absent from.
- `.chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl:10-22` — the dotted-path expansion that turns each declared leaf into the nested object handed to `settings-reconcile`.
- `.github/workflows/ci.yml:213-230` — how CI renders the provisioner and runs the guard test.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Declare both values as scalar leaves of `agents.codex.settings`.** The provisioner expands each dotted path into the object handed to `settings-reconcile`, so a top-level `model` leaf reaches `config.toml` as a top-level key. This is the same mechanism the existing four leaves use, and it needs no template change. (session-settled: user-directed — chosen over leaving `model` undeclared and effort at `high`: the user asked for the source to match this host's chosen values.) Instantiates the Key Decision governing R1, R3.
- KTD2. **Update the guard test's literals in place instead of loosening the assertion.** The assertion at `.ci/test-codex-settings-reconcile.sh:112-115` names the exact posture on purpose: it is what catches an accidental data edit. Replacing `.model_reasoning_effort == "high" and (has("model") | not)` with the two new equalities keeps that property.

### Assumptions

- The live `~/.codex/config.toml` still reads `gpt-6-astra` / `medium` when the change is implemented. R2 makes re-reading it a step, not an assumption to carry silently.
- `gpt-6-astra` is a bare TOML key value with no dot, so the declaration's path grammar is unaffected. Only the key path, not the value, passes through `codex-settings-validate.tmpl`.

### Sequencing

U1 then U2. U2's assertion describes the data U1 writes, so running U2's verification before U1 lands would fail by design.

---

## Implementation Units

### U1. Declare model and effort in the agents data

- **Goal:** `agents.codex.settings` carries the two values this host uses, and the comment above it records why.
- **Requirements:** R1, R2, R3, R4 (KTD1)
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:** Read `~/.codex/config.toml` first and confirm `model` and `model_reasoning_effort`; stop and report if either differs from `gpt-6-astra` / `medium` (R2). Change `model_reasoning_effort: high` to `medium` and add `model: gpt-6-astra` under `agents.codex.settings`. Rewrite the two comment lines that state the model is undeclared so they state the operator's model and effort are now asserted on every apply.
- **Test expectation:** none — pure data declaration; U2 owns the assertion.
- **Verification:** `chezmoi execute-template` on the provisioner renders without a validator failure, and the rendered heredoc JSON carries both values.

### U2. Move the guard test to the new posture

- **Goal:** The reconciler guard fails when the declaration drifts from `gpt-6-astra` / `medium`.
- **Requirements:** R5 (KTD2)
- **Files:** `.ci/test-codex-settings-reconcile.sh`
- **Approach:** In the declared-posture `jq -e` at lines 112-115, replace `.model_reasoning_effort == "high" and (has("model") | not)` with `.model_reasoning_effort == "medium" and .model == "gpt-6-astra"`. Leave the approval and sandbox clauses, the render-time cases, and the mcp_servers assertions untouched.
- **Test scenarios:**
  - Happy path: with U1 applied, `.ci/test-codex-settings-reconcile.sh <rendered-script>` prints `all runtime and render-time assertions passed`.
  - Regression guard: reverting `model_reasoning_effort` to `high` in the data, re-rendering the provisioner, and re-running makes the guard fail with `the declared headless posture is not the one agents.yaml declares`. The re-render is required: the test compares the rendered script against the live data, so a stale rendered script fails earlier on `the declared settings leaves do not expand to the rendered agents.codex.settings`.
  - Regression guard: removing the `model` leaf from the data and re-rendering makes the same run fail on the same posture assertion.
  - Unchanged coverage: the render-time negative cases (bad path, ancestor overlap, owned namespace, unreviewed security key) still pass, showing the validator was not touched.
- **Verification:** the full guard-test run below.

---

## Verification Contract

| Gate | Command | Applies to |
|---|---|---|
| Render the provisioner | `env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/70-agents/run_after_config-codex-settings.sh.tmpl > "$scratch/codex-settings.sh"` | U1 |
| Reconciler guard | `.ci/test-codex-settings-reconcile.sh "$scratch/codex-settings.sh"` (the test resolves `settings-reconcile` from `~/.local/bin` when present, else compiles it with `bun`, which needs `cd packages && bun install --frozen-lockfile` first) | U1, U2 |
| Shell lint | `shellcheck .ci/test-codex-settings-reconcile.sh` | U2 |
| Diff hygiene | `git diff --check` and `git status` | U1, U2 |

Use the scratch directory and stub `op` from the repository supplement's Verification section. Never apply to the live `$HOME`.

## Definition of Done

- Both leaves are declared in `.chezmoidata/agents.yaml` with the values read from the live config.
- The comment above the declaration no longer claims the model is undeclared.
- `.ci/test-codex-settings-reconcile.sh` asserts the new posture and passes against the rendered provisioner.
- The rendered provisioner's declared JSON carries `"model": "gpt-6-astra"` and `"model_reasoning_effort": "medium"`.
- `git diff` is limited to `.chezmoidata/agents.yaml` and `.ci/test-codex-settings-reconcile.sh`; no scratch or experimental files remain.
