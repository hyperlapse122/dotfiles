---
title: Skip Tailscale and MX Master 4 Haptics on Jetson AGX Thor - Plan
type: feat
date: 2026-08-15
topic: jetson-tailscale-haptic-skip
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Skip Tailscale and MX Master 4 Haptics on Jetson AGX Thor - Plan

## Goal Capsule

- **Objective:** Ensure the NVIDIA Jetson AGX Thor hardware profile cleanly skips Tailscale authentication and MX Master 4 haptic plugin/daemon provisioning at render and execution time without breaking non-Jetson hosts.
- **Authority:** The requested behavior is to skip Tailscale authentication on Jetson hosts via `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl` using `skip.sh.tmpl` (preventing render-time 1Password auth-key reads on Jetson) and ensure all mxm4-haptic components are properly gated/ignored on Jetson.
- **Execution profile:** Edit chezmoi source state only. Render changed templates with a scratch source, `--source "$PWD"`, and a stub `op`; never apply to the live home directory.
- **Stop conditions:** Stop if a change would break Tailscale auth or mxm4-haptic on Fedora/Darwin desktop hosts or Ubuntu non-Jetson environments. Stop if any skip declaration in `.ci/skip-declaration-site-matrix.yaml` or `.ci/check-skip-declarations.sh` becomes unaligned.
- **Tail ownership:** The implementation executor owns tests and leaves commit, push, and pull-request work to the LFG shipping stages.

---

## Product Contract

### Summary

On an NVIDIA Jetson AGX Thor developer kit (`jetson` fact = true), Tailscale is intentionally not joined and MX Master 4 haptic hardware does not exist. This plan implements clean skip declarations and template gates so that `run_once_after_auth-tailscale.sh.tmpl` declares a skip via `skip.sh.tmpl` without evaluating `onepasswordRead` for the Tailscale auth key, and ensures that mxm4-haptic components (marketplaces, plugins, build scripts, and units) are cleanly excluded from Jetson hosts.

### Problem Frame

1. `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl` was listed in `.chezmoiignore` as `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl`. Because chezmoi script targets omit `.tmpl`, this ignore rule did not match the rendered script target `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh`.
2. When `run_once_after_auth-tailscale.sh.tmpl` rendered without gating on Jetson, line 41 executed `onepasswordRead "op://Private/Tailscale/Auth Key"`. On a Jetson machine without tailnet credentials, this causes a render failure, and if executed, attempts to join Tailscale against policy.
3. The clean, established pattern in this repository for host-gated scripts is to evaluate `$facts.jetson` within the template and emit a declared skip via `skip.sh.tmpl` (`form: "not_applicable"`, `reason: "Jetson host intentionally stays off the tailnet"`), enclosing the `onepasswordRead` and execution logic inside the `{{ else }}` block.
4. For mxm4-haptic, Jetson hosts have no MX Master 4 hardware. The build script `run_after_build-mxm4-haptic.sh` and systemd units are ignored via `.chezmoiignore`, and the `h82-dotfiles` marketplace (`.local/share/omp-plugins`) and plugin updater must also cleanly skip `mxm4-haptic` on Jetson.

### Requirements

**Tailscale Authentication Gating**

- R1. `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl` resolves `$facts.jetson` via `facts.tmpl`. When `jetson` is true, the script emits a declared skip via `skip.sh.tmpl` with `form: "not_applicable"`, `site: "jetson-off-tailnet"`, and `reason: "Jetson host intentionally stays off the tailnet"`.
- R2. When `jetson` is true, `onepasswordRead "op://Private/Tailscale/Auth Key"` is never evaluated during template rendering.
- R3. On non-Jetson hosts (`jetson` is false), the existing Tailscale authentication flow remains byte-for-byte identical.

**Skip Declaration Matrix & Verification**

- R4. `.ci/skip-declaration-site-matrix.yaml` records the `auth-tailscale/jetson-off-tailnet` skip site with its normalized predicate and continuation digests.
- R5. `.ci/check-skip-declarations.sh` passes without errors on all render variants.

**MX Master 4 Haptic Exclusion on Jetson**

- R6. `.chezmoiignore` cleanly ignores mxm4-haptic components for Jetson (`.chezmoiscripts/60-build/*mxm4-haptic.sh`, `.config/systemd/user/mxm4-haptic*.service`, `.omp/agent/extensions/mxm4-haptic.ts`, `.local/share/omp-plugins`).
- R7. `.chezmoidata/agents.yaml` declares `jetson: skip` for `marketplaces.h82-dotfiles`, and `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl` filters out rows where `jetson` fact is true and `jetson: skip` is declared.
- R8. `.ci/test-mxm4-haptic-gates.sh` and all existing CI test fixtures pass cleanly.

### Key Flows

- F1. **Render on Jetson host:** `run_once_after_auth-tailscale.sh.tmpl` renders a shell script containing only the `skip.sh.tmpl` skip declaration; no 1Password secret is read; execution outputs a skip message and exits 0.
- F2. **Render on standard Fedora / Linux host:** `run_once_after_auth-tailscale.sh.tmpl` renders the complete Tailscale authentication script with `onepasswordRead` and existing logic.
- F3. **Plugin reconciliation on Jetson host:** `run_onchange_after_update-omp-plugins.sh.tmpl` skips the `mxm4-haptic` plugin row from `h82-dotfiles` while retaining `compound-engineering`.

---

## Technical Design

### High-Level Architecture

```
run_once_after_auth-tailscale.sh.tmpl
  ├── $facts.jetson == true  ──> skip.sh.tmpl (not_applicable / jetson-off-tailnet) [no op:// read]
  └── $facts.jetson == false ──> full Tailscale auth flow + op://Tailscale/Auth Key read
```

### Key Technical Decisions (KTDs)

- KTD1. **In-template skip declaration for Tailscale on Jetson:** (session-settled: user-directed — chosen over `.chezmoiignore` target exclusion). An in-template check using `skip.sh.tmpl` prevents `onepasswordRead` at render time, emits a structured skip log at runtime, and participates in `.ci/check-skip-declarations.sh` verification.
- KTD2. **Data-driven `jetson: skip` for `h82-dotfiles` marketplace:** (session-settled: user-directed — chosen over hardcoded plugin name checks). Parallels the existing `container: skip` attribute in `agents.marketplaces.h82-dotfiles` and `run_onchange_after_update-omp-plugins.sh.tmpl`.

---

## Implementation Plan

### U1. Add Jetson skip to `run_once_after_auth-tailscale.sh.tmpl`

- **Files:** `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl`
- **Approach:**
  1. Load facts via `{{- $facts := includeTemplate "facts.tmpl" . | fromYaml -}}`.
  2. If `$facts.jetson` is true, emit `{{ includeTemplate "skip.sh.tmpl" (dict "ctx" . "form" "not_applicable" "script" "auth-tailscale" "site" "jetson-off-tailnet" "reason" "Jetson host intentionally stays off the tailnet") | trim }}`.
  3. Place all existing platform-specific logic and the `onepasswordRead` line inside `{{ else }}`.
- **Verification:** Render with `jetson=true` (empty/dummy op) -> emits skip, no error. Render with `jetson=false` -> emits full script.

### U2. Update Skip Declaration Matrix & Checker

- **Files:** `.ci/skip-declaration-site-matrix.yaml`, `.ci/check-skip-declarations.sh`
- **Approach:**
  1. Add `auth-tailscale/jetson-off-tailnet` owner to `.ci/skip-declaration-site-matrix.yaml` with appropriate anchor and digests.
  2. Update instance counts in `.ci/check-skip-declarations.sh` if needed.
- **Verification:** Run `.ci/check-skip-declarations.sh` -> PASS.

### U3. Update `.chezmoiignore` and `agents.yaml` for Jetson Haptic Skipping

- **Files:** `.chezmoiignore`, `.chezmoidata/agents.yaml`, `.chezmoiscripts/70-agents/run_onchange_after_update-omp-plugins.sh.tmpl`
- **Approach:**
  1. In `.chezmoiignore`, update the `$f.jetson` block: remove the redundant `.chezmoiscripts/10-auth/run_once_after_auth-tailscale.sh.tmpl` line and ensure `.local/share/omp-plugins` is ignored on Jetson.
  2. In `.chezmoidata/agents.yaml`, add `jetson: skip` to `marketplaces.h82-dotfiles`.
  3. In `run_onchange_after_update-omp-plugins.sh.tmpl`, check `(not (and $facts.jetson (eq (index $authority "jetson" | default "") "skip")))`.
- **Verification:** Run `.ci/test-mxm4-haptic-gates.sh` and render updater on Jetson -> mxm4-haptic omitted.

### U4. Full Test Suite & Verification

- **Files:** `.ci/test-*.sh`
- **Approach:**
  1. Run `.ci/check-skip-declarations.sh`.
  2. Run `.ci/test-mxm4-haptic-gates.sh`.
  3. Run `.ci/test-jetson-installer-render.sh`.
  4. Run `.ci/test-fedora-fact-block-baseline.sh`.
- **Verification:** All tests exit 0.

---

## Verification Contract

| Test / Gate | Command / Target | Purpose |
|---|---|---|
| Skip declarations | `.ci/check-skip-declarations.sh` | Verify all skip sentinels match matrix |
| Haptic gates | `.ci/test-mxm4-haptic-gates.sh` | Verify haptic ignore and reconcile gates |
| Jetson installer | `.ci/test-jetson-installer-render.sh` | Verify Jetson installer rendering |
| Fedora baseline | `.ci/test-fedora-fact-block-baseline.sh` | Verify non-Jetson baseline remains unchanged |
| Shell syntax | `bash -n` on all rendered scripts | Verify rendered shell validity |
