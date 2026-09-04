---
title: "refactor: Remove custom-defined agy tool definition from AoE config"
type: refactor
date: 2026-09-04
topic: remove-aoe-custom-agy-tool
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Remove Custom-Defined `agy` Tool Definition from AoE Config - Plan

## Goal Capsule

**Objective.** Remove the custom-defined `agy` tool entries from Agent of Empires (AoE) configuration in dotfiles so AoE relies on its native Antigravity support instead of a custom agent shim.

**Means.** Delete `agy: agy` from `session.custom_agents` and `session.agent_detect_as` under `agents.aoe.config.toml` in `.chezmoidata/agents.yaml`. Verify that settings reconciliation and chezmoi templates render cleanly without error.

**Product authority.** User request: "remove custom-defined `agy` tool definition from aoe config in dot_config/agent-of-empires since aoe natively supports antigravity tool now".

**Open blockers.** None.

---

## Product Contract

### Summary

Agent of Empires (`aoe`) now natively supports `antigravity` as a built-in AI coding agent (`aoe agents` lists `antigravity` as a supported agent). The custom agent registration `agy: agy` under `custom_agents` and `agent_detect_as` in `.chezmoidata/agents.yaml` is now redundant and can cause duplicate or conflicting agent detection in AoE. Removing `agy` from `.chezmoidata/agents.yaml` leaves AoE's global config clean and aligned with native tool discovery.

### Requirements

- **R1.** `.chezmoidata/agents.yaml` must not declare `agy` under `agents.aoe.config.toml.session.custom_agents` or `agents.aoe.config.toml.session.agent_detect_as`.
- **R2.** The surviving custom agents (`zsh: zsh`, `claude: claude` under `custom_agents`, and `claude: claude` under `agent_detect_as`) and all other aoe settings (e.g. `tmux`) must remain byte-preserved.
- **R3.** Chezmoi templates depending on `agents.aoe` (specifically `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl`) must render valid JSON configuration without error.
- **R4.** No teardown/revert script is introduced. As established by repo rules and previous agent decommissions (e.g. OMP, Kimi, ZAI), live `~/.config/agent-of-empires/config.toml` on already-provisioned hosts retains unmanaged keys by design unless manually pruned.

### Acceptance Examples

- **AE1.** Inspecting `.chezmoidata/agents.yaml` confirms no `agy:` key under `agents.aoe.config.toml`.
- **AE2.** Running `chezmoi execute-template` on `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl` produces valid JSON containing `zsh` and `claude` without `agy`.
- **AE3.** All existing test suites pass.

---

## Planning Contract

### Key Decisions

- **KTD1. Single-source modification in `.chezmoidata/agents.yaml`.** (session-settled: user-directed)
  AoE's global configuration is managed via `.chezmoidata/agents.yaml` (`agents.aoe.config.toml`), which is merged into `~/.config/agent-of-empires/config.toml` by `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl`. `dot_config/agent-of-empires/profiles/main/private_config.toml.tmpl` manages profile-specific settings (which currently does not declare `agy`). Modifying `.chezmoidata/agents.yaml` is the correct single source of truth.
- **KTD2. No teardown scripts or automated deletion of unmanaged keys in live config.** (session-settled: repo-mandated)
  Per root `AGENTS.md` and previous decommission precedents, `settings-reconcile` merges declared keys and preserves undeclared keys. No teardown script will be added.

### Technical Design

In `.chezmoidata/agents.yaml`:
```yaml
  aoe:
    config.toml:
      session:
        custom_agents:
          zsh: zsh
          claude: claude
        agent_detect_as:
          claude: claude
      tmux:
        status_bar: enabled
        clipboard: enabled
```

---

## Implementation Units

### U1. Remove `agy` from `.chezmoidata/agents.yaml`

**Goal.** Delete `agy: agy` under `custom_agents` and `agent_detect_as` in `.chezmoidata/agents.yaml`.

**Tasks.**
1. Edit `.chezmoidata/agents.yaml` lines 86-94 to remove `agy: agy` from `custom_agents` and `agent_detect_as`.
2. Ensure indentation and YAML syntax remain valid.

**Verification.**
- YAML parsing succeeds.
- Grep confirms no `agy` under `agents.aoe`.

### U2. Verify Chezmoi template rendering and test suite

**Goal.** Ensure `.chezmoiscripts/70-agents/run_after_config-aoe.sh.tmpl` renders cleanly and existing repository tests pass.

**Tasks.**
1. Test rendering of the aoe config JSON via `chezmoi execute-template`.
2. Run test suites (`bun test` in packages, `.ci` scripts where applicable).

**Verification.**
- Rendered JSON contains `zsh` and `claude`, but not `agy`.
- Test suite passes.

---

## Verification Contract

- Run `chezmoi execute-template --source "$PWD" '{{ index .agents.aoe "config.toml" | toPrettyJson }}'` to verify rendered JSON.
- Run `bun test` in `packages/settings-reconcile`.
- Run `.ci/test-ci-wiring.sh` or related CI checks if applicable.

---

## Definition of Done

- [x] Plan completed and reviewed.
- [ ] `agy` removed from `agents.aoe.config.toml` in `.chezmoidata/agents.yaml`.
- [ ] Rendered JSON verified.
- [ ] All tests pass.
