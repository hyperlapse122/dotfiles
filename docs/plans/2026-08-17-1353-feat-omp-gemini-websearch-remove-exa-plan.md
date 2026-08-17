---
title: OMP Gemini Web Search and Exa Disconnection
topic: omp-gemini-websearch-remove-exa
type: feat
created_at: 2026-08-17
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# OMP Gemini Web Search and Exa Disconnection - Plan

## Goal Capsule

- **Objective:** Configure OMP's native web search grounding to use `gemini-3.7-flash` and completely decouple the Exa search integration (MCP server, credentials, OMP settings, and closed-set test fixtures).
- **Product Authority:** User instruction via `ce-brainstorm` session.
- **Execution Profile:** `execution: code`
- **Open Blockers:** None.

## Product Contract

### Summary
Update `.chezmoidata/agents.yaml` to set `providers.webSearchGeminiModel` to `gemini-3.7-flash` and prioritize `gemini` in `providers.webSearchOrder`. Completely remove Exa from MCP servers, OMP settings, and OMP environment credentials, narrowing the managed auth closed set to `OPENROUTER_API_KEY` across provisioners and CI tests.

### Problem Frame
OMP defaults its Gemini search grounding model to `gemini-2.5-flash` when unspecified. The active configuration also links Exa via an HTTP MCP server (`websearch`), an OMP setting (`exa.enabled: true`), `providers.webSearchOrder: [exa, gemini]`, and an explicit 1Password reference `EXA_API_KEY` in `agents.omp.auth.env`. To streamline web search around Google Antigravity/Gemini grounding and remove unused Exa dependencies, Exa should be unlinked and Gemini 3.7 Flash should be asserted as the search grounding model.

### Key Decisions
- **KD1. Complete removal of Exa across data, provisioners, and tests** (session-settled: user-directed — chosen over keeping Exa disabled in OMP settings only: completely removes unused Exa MCP definitions and credentials). Governs R2, R3, R4, R5, R6, R7.
- **KD2. Explicit Gemini search model assertion** (session-settled: user-directed — configures `providers.webSearchGeminiModel: gemini-3.7-flash` in OMP settings). Governs R1.
- **KD3. Omission of explicit Exa exclusion guards** (session-settled: user-directed — chosen over adding Exa to `disabledProviders` or `providers.webSearchExclude`: credential and configuration removal is sufficient). Governs R2, R3.

### Requirements

**OMP Web Search Configuration**
- R1. `.chezmoidata/agents.yaml`'s `agents.omp.settings` asserts `providers.webSearchGeminiModel: gemini-3.7-flash`.
- R2. `.chezmoidata/agents.yaml`'s `agents.omp.settings.providers.webSearchOrder` contains only `[gemini]`.
- R3. `.chezmoidata/agents.yaml`'s `agents.omp.settings` does not contain `exa.enabled`.

**MCP and Auth Closed-Set Narrowing**
- R4. `.chezmoidata/agents.yaml`'s `agents.mcp.servers` contains no `websearch` (https://mcp.exa.ai/mcp) entry.
- R5. `.chezmoidata/agents.yaml`'s `agents.omp.auth.env` declares exactly `OPENROUTER_API_KEY` (with `op://Private/OpenRouter/API Key`), containing no `EXA_API_KEY` record.
- R6. `.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl` enforces the narrowed single-variable closed set (`$required := list "OPENROUTER_API_KEY"`).

**CI & Test Alignment**
- R7. `.ci/test-omp-agent-reconcile.sh` asserts the narrowed single-variable managed set (`OPENROUTER_API_KEY`), removing all active `EXA_API_KEY` sentinels, duplicate tests, and expected-name fixtures.

### Scope Boundaries
- **Deferred for later:** Adding other search providers or custom Gemini grounding endpoints.
- **Non-goals:** Adding explicit `disabledProviders` or `providers.webSearchExclude` entries for Exa; modifying unrelated OMP model roles, fallback chains, or other MCP servers (`codegraph`, `glab`, `agent-browser`, `context7`).

### Acceptance Examples
- AE1. Covers R1, R2, R3. Given `.chezmoidata/agents.yaml`, when `run_after_config-omp-settings.sh.tmpl` renders, it sets `providers.webSearchGeminiModel` to `gemini-3.7-flash`, `providers.webSearchOrder` to `[gemini]`, and emits no `exa.enabled` command.
- AE2. Covers R4. Given `.chezmoidata/agents.yaml`, when MCP server templates render, no `websearch` or `mcp.exa.ai` server is emitted.
- AE3. Covers R5, R6. Given a test dotenv file with `OPENROUTER_API_KEY` and unrelated tokens, when `run_after_config-omp-auth.sh.tmpl` runs, it reconciles only `OPENROUTER_API_KEY` without error.
- AE4. Covers R7. When `.ci/test-omp-agent-reconcile.sh` runs, all auth reconciliation assertions pass with the single-variable closed set.

## Planning Contract

### Key Technical Decisions
- **KTD1. Single-variable closed-set auth validation.** The `$required` list in `run_after_config-omp-auth.sh.tmpl` narrows from `list "EXA_API_KEY" "OPENROUTER_API_KEY"` to `list "OPENROUTER_API_KEY"`, preserving strict member check and fail-closed validation against injected variables. Governs R5, R6.
- **KTD2. Direct setting assertion without fallback padding.** `providers.webSearchGeminiModel` is placed alongside `providers.webSearchOrder` in `agents.omp.settings`, relying on OMP's native setting assertion script `run_after_config-omp-settings.sh.tmpl`. Governs R1, R2.

### High-Level Technical Design
```mermaid
flowchart TD
  A[".chezmoidata/agents.yaml"] -->|auth.env| B["run_after_config-omp-auth.sh.tmpl"]
  A -->|omp.settings| C["run_after_config-omp-settings.sh.tmpl"]
  A -->|mcp.servers| D["agent-mcp-servers-json.tmpl"]

  B -->|closed set: OPENROUTER_API_KEY| E["~/.omp/agent/.env"]
  C -->|webSearchGeminiModel: gemini-3.7-flash, webSearchOrder: [gemini]| F["~/.omp/agent/config.yml"]
  D -->|no exa server| G["~/.omp/agent/mcp.json"]

  H[".ci/test-omp-agent-reconcile.sh"] -->|validates| B
  H -->|validates| C
```

## Implementation Units

### U1. Update Agents Data for Web Search, MCP, and Auth
- **Goal:** Update `.chezmoidata/agents.yaml` to configure Gemini search model, remove Exa settings, delete the Exa MCP server, and narrow auth environment variables to `OPENROUTER_API_KEY`.
- **Files:** `.chezmoidata/agents.yaml`
- **Patterns to follow:** Existing `agents.omp.settings` and `agents.omp.auth.env` maps.
- **Test Scenarios:**
  - `agents.mcp.servers` has 4 entries (`codegraph`, `glab`, `agent-browser`, `context7`) and no `websearch`.
  - `agents.omp.settings.providers.webSearchGeminiModel` equals `"gemini-3.7-flash"`.
  - `agents.omp.settings.providers.webSearchOrder` equals `["gemini"]`.
  - `agents.omp.settings.exa.enabled` is absent.
  - `agents.omp.auth.env` contains only `OPENROUTER_API_KEY`.

### U2. Narrow Auth Provisioner Closed Set
- **Goal:** Update `.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl` to enforce the single-variable closed set `["OPENROUTER_API_KEY"]`.
- **Files:** `.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl`
- **Patterns to follow:** Strict `$required` list check.
- **Test Scenarios:**
  - Script renders without error when `agents.omp.auth.env` declares `OPENROUTER_API_KEY`.
  - Script fails at template render if any other variable (or missing variable) is declared.

### U3. Update CI Reconcile Test Harness
- **Goal:** Align `.ci/test-omp-agent-reconcile.sh` with the single-variable `OPENROUTER_API_KEY` closed set.
- **Files:** `.ci/test-omp-agent-reconcile.sh`
- **Patterns to follow:** Existing `.env` reconciliation fixture tests and negative assertion checks.
- **Test Scenarios:**
  - `expected_names` contains only `OPENROUTER_API_KEY`.
  - Dotenv reconciliation tests assert `OPENROUTER_API_KEY` presence and correct mode `0600`.
  - Negative render assertions check `must declare OPENROUTER_API_KEY` on empty list and reject unsupported variables.

## Verification Contract

### Automated Verification
```bash
# 1. Run omp agent reconcile test suite
bash .ci/test-omp-agent-reconcile.sh

# 2. Verify template rendering in isolation
scratch=$(mktemp -d)
mkdir -p "$scratch/bin" "$scratch/target"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
env PATH="$scratch/bin:$PATH" chezmoi --config /dev/null --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl >/dev/null
env PATH="$scratch/bin:$PATH" chezmoi --config /dev/null --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl >/dev/null
rm -rf "$scratch"
```

## Definition of Done
- [ ] `.chezmoidata/agents.yaml` has `providers.webSearchGeminiModel: gemini-3.7-flash` and `providers.webSearchOrder: [gemini]`.
- [ ] `.chezmoidata/agents.yaml` has no `exa.enabled`, no `websearch` MCP server, and no `EXA_API_KEY` in `auth.env`.
- [ ] `.chezmoiscripts/70-agents/run_after_config-omp-auth.sh.tmpl` enforces `$required := list "OPENROUTER_API_KEY"`.
- [ ] `.ci/test-omp-agent-reconcile.sh` passes completely with all closed-set assertions updated.
- [ ] Clean `git diff` with no leftover Exa references in active configuration.
