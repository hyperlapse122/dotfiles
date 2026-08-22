---
title: Set OMP TUI Resize Scrollback to Rebuild - Plan
type: feat
date: 2026-08-22
topic: omp-resize-scrollback-rebuild
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Set OMP TUI Resize Scrollback to Rebuild - Plan

## Goal Capsule

- **Objective:** Assert `tui.resizeScrollback: rebuild` into oh-my-pi's (`omp`) configuration via `.chezmoidata/agents.yaml` so terminal pane resizes (e.g. in tmux) clear pane history before repainting rather than duplicating the transcript.
- **Means:** Data-only addition to `agents.omp.settings` in `.chezmoidata/agents.yaml`.
- **Authority:** User directive referencing oh-my-pi release v18.0.0 and `AGENTS.md` data-driven configuration rules.
- **Execution profile:** Single data edit verified by isolated template rendering and `.ci/test-omp-agent-reconcile.sh`.
- **Stop conditions:** Stop if `omp-settings-validate.tmpl` fails validation or if `run_after_config-omp-settings.sh.tmpl` fails execution.
- **Tail ownership:** Invoking LFG pipeline handles commit, branch rename, push, PR creation, and CI watch.

---

## Product Contract

### Summary

Add `tui.resizeScrollback: rebuild` to `agents.omp.settings` in `.chezmoidata/agents.yaml`. Oh-my-pi v18.0.0 introduced the `tui.resizeScrollback` enum setting (`append|rebuild|preserve`, defaulting to `append`). In multiplexers like tmux, `rebuild` clears the history first (using ED3) so it holds exactly one current-width copy instead of appending duplicated transcripts on width changes.

### Requirements

- R1. `.chezmoidata/agents.yaml` declares `tui.resizeScrollback: rebuild` under `agents.omp.settings`.
- R2. `tui.scrollbackRebuild: true` remains intact and declared.
- R3. The template validation in `.chezmoitemplates/omp-settings-validate.tmpl` and script in `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` accept the setting without errors.
- R4. Verification test `.ci/test-omp-agent-reconcile.sh` passes completely.

### Scope Boundaries

- No template or script code modifications needed; data-only addition.
- No changes to model roles, tool approvals, or marketplace plugins.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Add `tui.resizeScrollback: rebuild` directly adjacent to `tui.scrollbackRebuild: true` in `agents.omp.settings` in `.chezmoidata/agents.yaml`.
- KTD2. Keep `tui.resizeScrollback` as a plain scalar string (`rebuild`), adhering to safe YAML and regex grammar rules (`^[A-Za-z0-9 ._:/@*+-]*$`).
- KTD3. Ensure `.ci/test-omp-agent-reconcile.sh` and template execution validate cleanly in an isolated test environment.

---

## Implementation Units

### U1. Add tui.resizeScrollback to agents.omp.settings

- **Goal:** Declare `tui.resizeScrollback: rebuild` in `.chezmoidata/agents.yaml`.
- **Requirements:** R1, R2, R3, R4
- **Files:** `.chezmoidata/agents.yaml`
- **Approach:** Edit `.chezmoidata/agents.yaml` to insert `tui.resizeScrollback: rebuild` right after `tui.scrollbackRebuild: true`.
- **Test Scenarios:**
  - `chezmoi execute-template` on `run_after_config-omp-settings.sh.tmpl` succeeds.
  - The rendered declared settings JSON contains `"tui.resizeScrollback": "rebuild"`.
  - `.ci/test-omp-agent-reconcile.sh` passes.

---

## Verification Contract

| Gate | Check | Covers |
|---|---|---|
| G1 | `chezmoi execute-template` renders `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` with exit 0 | R1, R3 |
| G2 | Rendered JSON contains `"tui.resizeScrollback": "rebuild"` | R1 |
| G3 | `.ci/test-omp-agent-reconcile.sh` passes | R3, R4 |
| G4 | `git diff --check` is clean and scoped to `.chezmoidata/agents.yaml` | R1 |

---

## Definition of Done

- **Global:** U1 complete, all verification gates G1–G4 pass.
