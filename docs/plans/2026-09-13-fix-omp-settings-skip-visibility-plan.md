---
title: Make omp settings reconciler missing-precondition skips visible - Plan
type: fix
date: 2026-09-13
topic: fix-omp-settings-skip-visibility
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Make omp settings reconciler missing-precondition skips visible - Plan

## Goal Capsule

- **Objective:** Record declared skip states when `omp` or `jq` is absent during `run_after_config-omp-settings.sh.tmpl` execution, making them visible to `dotfiles-skips` while keeping the apply non-blocking (exit 0) and clearing stale skip records upon convergence.
- **Means:** Declare skips using `.chezmoitemplates/skip.sh.tmpl` with `form: "skip_here"`, `direction: "transient-blocking"`, and probe identifiers (`omp-present` and `jq-present`). Remove stale skip records when the missing precondition passes or when settings assertion succeeds. Update `.ci/test-omp-settings-reconcile.sh` to verify skip record creation, skip output, and record removal.
- **Product authority:** Issue #449 (`fix(omp): make the settings reconciler's missing-precondition skips visible`) and PR #445 unapplied review finding.
- **Execution profile:** Source files only. Edit `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl` and `.ci/test-omp-settings-reconcile.sh`. Do not touch deployed `$HOME`.
- **Stop conditions:** If `check-skip-declarations.sh` or `test-capability-cache.sh` requires adding `run_after_` sites to the frozen R5 matrix `.ci/skip-declaration-site-matrix.yaml`.
- **Tail ownership:** CI validation across tests.

---

## Product Contract

### Summary

The `run_after_config-omp-settings.sh.tmpl` script asserts declared `omp` settings into `~/.omp/agent/config.yml` on every apply. When `omp` or `jq` is missing, the script previously printed an explanation to stderr and exited with a bare `exit 0`. As noted in PR #445 and issue #449, these bare exits are invisible to `dotfiles-skips`.

This fix converts those early exits to declared skips using `skip.sh.tmpl` (`form: "skip_here"`, `direction: "transient-blocking"`). This ensures `dotfiles-skips` reports the deferred assertion, while preserving the non-blocking apply semantics required of `run_after_` scripts. It also ensures stale skip records are cleaned up when the binaries are available and settings are converged.

### Problem Frame

`run_after_config-omp-settings.sh.tmpl` runs after file targets on every apply. A missing `omp` or `jq` binary does not necessarily indicate a fatal apply error, because `65-commands` swallows command reconciliation failures and omp can be absent in early stages or intentionally uninstalled. Failing loudly (exiting 1) would strand subsequent phases (`80-keys` and `90-src`).

However, exiting 0 silently without recording a skip state hides the fact that omp settings were never configured. `dotfiles-skips` provides visibility into unconverged host states by reading skip record files in `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/`. Converting these exits to declared skips restores visibility without breaking the fail-open contract.

### Key Decisions

- KD1. **Use `skip.sh.tmpl` with `transient-blocking` rather than `transient-tolerable` or bare `exit 0`.** `transient-tolerable` emits `exit 1`, which would strand later phases (`80-keys`, `90-src`) during `chezmoi apply`. `transient-blocking` exits 0 while writing a skip record that `dotfiles-skips` reports.
- KD2. **Retain lifecycle exclusion for post-R5 `run_after_` scripts in `.ci/skip-declaration-site-matrix.yaml`.** As established in PR #486 and documented in AGENTS.md, `run_after_` scripts run on every apply and are excluded by lifecycle from the frozen R5 matrix. `check-skip-declarations.sh` already accounts for `run_after_` scripts as excluded by lifecycle. Do not add owner rows to `.ci/skip-declaration-site-matrix.yaml` or alter probe counts in `.ci/test-capability-cache.sh`.
- KD3. **Explicitly clean up skip records on convergence and capability appearance.** In `run_after_config-omp-settings.sh.tmpl`, when `command -v omp` succeeds, remove any existing `config-omp-settings__omp-unavailable` skip record. When `command -v jq` succeeds, remove any existing `config-omp-settings__jq-unavailable` skip record. This ensures that once both preconditions are met, `dotfiles-skips` stops reporting them.

### Requirements

- R1. In `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, the early exit for missing `omp` MUST use `skip.sh.tmpl` with `form: "skip_here"`, `direction: "transient-blocking"`, `probe: "omp-present"`, `site: "omp-unavailable"`, and `reason: "omp is unavailable; settings assertion is deferred"`.
- R2. In `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, the early exit for missing `jq` MUST use `skip.sh.tmpl` with `form: "skip_here"`, `direction: "transient-blocking"`, `probe: "jq-present"`, `site: "jq-unavailable"`, and `reason: "jq is unavailable; settings assertion is deferred"`.
- R3. In `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, whenever `omp` is present, the script MUST remove any stale `config-omp-settings__omp-unavailable` skip record.
- R4. In `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`, whenever `jq` is present, the script MUST remove any stale `config-omp-settings__jq-unavailable` skip record.
- R5. `.ci/test-omp-settings-reconcile.sh` MUST assert that when `omp` is absent, the script exits 0, outputs the declared skip message, and writes the `config-omp-settings__omp-unavailable` skip record.
- R6. `.ci/test-omp-settings-reconcile.sh` MUST assert that when `jq` is absent, the script exits 0, outputs the declared skip message, and writes the `config-omp-settings__jq-unavailable` skip record.
- R7. `.ci/test-omp-settings-reconcile.sh` MUST assert that on the converged happy path, any prior skip records for `config-omp-settings` are removed.
- R8. `.ci/check-skip-declarations.sh` and `.ci/test-capability-cache.sh` MUST continue to pass cleanly without modifying `.ci/skip-declaration-site-matrix.yaml` or `.chezmoidata/.capability-registry.tsv`.

---

## Technical Architecture & Implementation Units

### U1: Declare Skips in `run_after_config-omp-settings.sh.tmpl`

**Target:** `.chezmoiscripts/70-agents/run_after_config-omp-settings.sh.tmpl`

Replace bare early exits:
```bash
if ! command -v omp >/dev/null 2>&1; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "skip_here" "script" "config-omp-settings" "site" "omp-unavailable" "direction" "transient-blocking" "probe" "omp-present" "reason" "omp is unavailable; settings assertion is deferred") | trim | indent 2 }}
fi
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/config-omp-settings__omp-unavailable" 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "skip_here" "script" "config-omp-settings" "site" "jq-unavailable" "direction" "transient-blocking" "probe" "jq-present" "reason" "jq is unavailable; settings assertion is deferred") | trim | indent 2 }}
fi
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/config-omp-settings__jq-unavailable" 2>/dev/null || true
```

### U2: Update Reconciliation Tests in `.ci/test-omp-settings-reconcile.sh`

**Target:** `.ci/test-omp-settings-reconcile.sh`

Update the `no-jq` and `no-omp` scenarios:
1. Ensure helper utilities like `mkdir` and `rm` remain accessible in the test's isolated PATH so `skip.sh.tmpl` can write state files.
2. Verify that the skip file `${home}/.local/state/chezmoi/skips/config-omp-settings__jq-unavailable` is written with the expected tab-separated fields.
3. Verify that the skip file `${home}/.local/state/chezmoi/skips/config-omp-settings__omp-unavailable` is written with the expected tab-separated fields.
4. Verify stdout contains the declared skip message `config-omp-settings: ... is unavailable; settings assertion is deferred. Recorded as done; it re-runs automatically once ... changes.`
5. In the converged run, verify that pre-seeded skip records are removed.

---

## Verification Plan

- Run `.ci/test-omp-settings-reconcile.sh` against the rendered template.
- Run `.ci/check-skip-declarations.sh` to ensure no matrix or declaration regressions.
- Run `.ci/test-capability-cache.sh` to ensure registry/matrix invariants hold.
