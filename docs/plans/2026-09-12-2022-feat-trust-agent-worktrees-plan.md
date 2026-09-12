---
title: Trust Agent Worktrees in Managed Harnesses - Plan
type: docs
date: 2026-09-12
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: https://github.com/hyperlapse122/dotfiles/issues/436
---

# Trust Agent Worktrees in Managed Harnesses - Plan

## Goal Capsule

- **Objective:** Ensure all checkouts under `~/src` and worktrees under `~/.local/share/worktrees` are trusted by default across all managed agent harnesses (`claude`, `codex`, `agy`), eliminating interactive trust prompts during unattended runs (`lfg`, `codex exec`, Orca-dispatched workers) and normal use.
- **Means:**
  1. Provide a standalone command `agent-trust-reconcile` (managed via `commands.yaml`) that additively seeds trust into `~/.claude.json`, `~/.codex/config.toml`, and `~/.gemini/antigravity-cli/settings.json`.
  2. Provide an apply-time script `.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl` that reconciles trust for all checkouts and worktrees after garden grow and Orca registration.
  3. Provide an `orca-ide` command wrapper in `dot_local/share/chezmoi-command-sources/executable_orca-ide` (managed via `commands.yaml`) that intercepts `orca-ide worktree create` and immediately seeds trust for the newly created worktree.
  4. Provide a CI gate `.ci/test-agent-trust-reconcile.sh` wired into `.github/workflows/ci.yml` and validated by `.ci/test-ci-wiring.sh`.
- **Authority:** Issue #436 defines acceptance criteria and scope. Dotfiles `AGENTS.md` governs command reconciliation, script lifecycles, and agent settings.
- **Stop conditions:** Stop if any test fails or if existing trust entries/unrelated settings are clobbered.
- **Execution profile:** Four implementation units (standalone command, apply-time runner, orca-ide wrapper, CI test and wiring).
- **Tail ownership:** Pipeline owns commit, push, PR, and CI watch.

---

## Product Contract

### Summary

Agent harnesses (`claude`, `codex`, `agy`) require user confirmation before executing actions in untrusted directories. In automated pipelines and Orca agent sessions, interactive trust dialogs cannot be answered, leading to stalled runs or degraded functionality. Because none of the three harnesses supports parent-directory prefix wildcards for project trust, every git checkout under `~/src` and worktree under `~/.local/share/worktrees` must be explicitly registered in each harness's trust store.

This change automates trust seeding at two points in the lifecycle:
1. **At `chezmoi apply` time:** `run_after_trust-agent-worktrees.sh.tmpl` scans `~/src` and `~/.local/share/worktrees` and asserts trust for all discovered checkouts in `~/.claude.json`, `~/.codex/config.toml`, and `~/.gemini/antigravity-cli/settings.json`.
2. **At worktree creation time:** The `orca-ide` CLI wrapper intercepts `orca-ide worktree create`, captures the created worktree path, and immediately runs `agent-trust-reconcile <path>`.

All mutations are strictly additive and atomic: existing trust entries and unrelated configuration keys are preserved intact.

### Problem Frame

- `claude` records trust in `~/.claude.json` under `projects."<abs_path>".hasTrustDialogAccepted = true`. It inspects ancestors only up to the git repository root; parent folders like `~/src` or `~/.local/share/worktrees` are ignored.
- `codex` records trust in `~/.codex/config.toml` under `[projects."<abs_path>"] trust_level = "trusted"`. It checks exact string paths with no prefix matching.
- `agy` (Antigravity CLI) records trust in `~/.gemini/antigravity-cli/settings.json` under `"trustedWorkspaces": [ "<abs_path>", ... ]`. It checks exact string membership in the array.
- `omp` (oh-my-pi) unconditionally trusts all projects (`isProjectTrusted()` always returns `true`), so no trust state is required for it.
- Orca's internal `createManagedWorktree` only trusts `codex` when `--agent` is passed; bare worktree creation and other harnesses receive no trust seeding.

### Requirements

- R1. `agent-trust-reconcile` supports reconciling explicit directory paths passed as arguments, or scanning `~/src` and `~/.local/share/worktrees` when invoked with `--all` or no arguments.
- R2. `agent-trust-reconcile` seeds `hasTrustDialogAccepted = true` into `projects.<path>` in `~/.claude.json`, preserving all other keys and projects.
- R3. `agent-trust-reconcile` seeds `trust_level = "trusted"` into `[projects."<path>"]` in `~/.codex/config.toml`, using `settings-reconcile` (or equivalent additive TOML update), preserving all other tables, keys, and projects.
- R4. `agent-trust-reconcile` adds `<path>` to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json` without duplicates, preserving all other keys.
- R5. All file writes are atomic (write to temp file in same directory or XDG runtime, set 0600 mode, rename).
- R6. `run_after_trust-agent-worktrees.sh.tmpl` runs during `chezmoi apply` in phase `90-src` after garden grow and Orca registration, calling `agent-trust-reconcile`.
- R7. `executable_orca-ide` wraps `orca-ide` via `commands.yaml`. When `worktree create` succeeds with exit 0, it extracts the created worktree path from the output and invokes `agent-trust-reconcile <path>`. All other invocations exec the real `orca-ide` binary directly.
- R8. CI test `.ci/test-agent-trust-reconcile.sh` tests discovery, explicit paths, preservation of existing keys, idempotency, and the `orca-ide` wrapper interception.
- R9. `.ci/test-ci-wiring.sh` and `.github/workflows/ci.yml` wire and pass `.ci/test-agent-trust-reconcile.sh`.

---

## Technical Design & Key Decisions

### Decision 1: Python 3 for `agent-trust-reconcile`

`agent-trust-reconcile` is implemented as an executable Python 3 script (`dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile`):
- Python 3 is ubiquitous across Linux and Darwin in this repository.
- Built-in `json`, `os`, `pathlib`, `subprocess`, and `tempfile` modules eliminate external runtime dependencies.
- Pruning `os.walk` at `.git` roots completes repository discovery across 30+ checkouts in under 2ms.
- Atomic file replacement (`os.replace`) with mode `0o600` ensures clean, concurrent-safe writes.
- For Codex `config.toml`, it integrates with `settings-reconcile` (`~/.local/bin/settings-reconcile` or `$RECONCILER`), passing an overlay JSON payload, with a resilient fallback parser if `settings-reconcile` is uncompiled.

### Decision 2: Managed `orca-ide` wrapper in `commands.yaml`

Rather than modifying user dotfiles manually, `orca-ide` is declared as a `source` command unit in `.chezmoidata/commands.yaml`:
- The wrapper script `executable_orca-ide` is located in `dot_local/share/chezmoi-command-sources/`.
- It locates the real `orca-ide` binary via `$ORCA_REAL_BIN`, `$ORCA_IDE_CLI`, `${ORCA_PREFIX:-/opt/Orca}/resources/bin/orca-ide`, or `/Applications/Orca.app/Contents/Resources/bin/orca-ide`, explicitly rejecting `$0` / self to prevent recursion.
- For `worktree create`, it buffers stdout, prints stdout unchanged, and on exit 0 extracts the new path (supporting both human and `--json` outputs) and invokes `agent-trust-reconcile <path>`.

### Decision 3: Placement in `90-src`

`run_after_trust-agent-worktrees.sh.tmpl` is placed in `.chezmoiscripts/90-src/`:
- In chezmoi sort order, `trust-agent-worktrees` sorts lexically after `reconcile-garden` and `register-orca`.
- This guarantees all garden projects are freshly grown and registered before trust is stamped.
- It runs on every apply (`run_after_`), so worktrees created outside chezmoi between applies are immediately caught and trusted.

---

## Implementation Units

### Unit 1: Standalone Trust Reconciler Command
- **Files:**
  - `dot_local/share/chezmoi-command-sources/executable_agent-trust-reconcile`
  - `.chezmoidata/commands.yaml`
- **Actions:**
  - Implement the Python 3 script with discovery, path arguments, atomic writes, and harness-specific update logic for `claude`, `codex`, and `agy`.
  - Add `agent-trust-reconcile` unit to `.chezmoidata/commands.yaml` under `units`.

### Unit 2: `orca-ide` CLI Wrapper
- **Files:**
  - `dot_local/share/chezmoi-command-sources/executable_orca-ide`
  - `.chezmoidata/commands.yaml`
- **Actions:**
  - Implement wrapper script handling candidate search, recursion prevention, pass-through execution, and `worktree create` post-exit-0 trust reconciliation.
  - Add `orca-ide-wrapper` unit to `.chezmoidata/commands.yaml` under `units`.

### Unit 3: Apply-Time Runner
- **Files:**
  - `.chezmoiscripts/90-src/run_after_trust-agent-worktrees.sh.tmpl`
- **Actions:**
  - Call `agent-trust-reconcile` on every apply in `90-src`, with proper skip declarations and fingerprint comments.

### Unit 4: CI Test & CI Workflow Wiring
- **Files:**
  - `.ci/test-agent-trust-reconcile.sh`
  - `.github/workflows/ci.yml`
- **Actions:**
  - Author comprehensive test script verifying isolation, discovery, idempotency, non-destructive merging, and wrapper interception.
  - Wire into `.github/workflows/ci.yml` under `agent-reconciliation` job.
  - Verify with `.ci/test-ci-wiring.sh`.

---

## Verification Plan

1. Run `.ci/test-agent-trust-reconcile.sh` locally.
2. Run `.ci/test-ci-wiring.sh` to confirm all `.ci` gates are accounted for.
3. Run `.ci/test-codex-settings-reconcile.sh` and `.ci/test-claude-settings-reconcile.sh` to ensure no regressions in existing settings tests.
4. Verify idempotency and preservation of existing trust in live environment.
