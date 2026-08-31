---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Feature: 1Password Authentication Dialog Always on Top in KWin

## Goal Capsule

- **Objective**: Keep the 1Password authentication/unlock dialog window always on top (`keepAbove: true`) under KDE Plasma 6 (Wayland) so that switching focus to another window does not hide the dialog behind other windows.
- **Means**: Declare KWin window rules in `.chezmoidata/kde.yaml` targeting `kwinrulesrc` with `wmclass: 1password` and exact title `1Password`, setting `above: true` and `aboverule: 3` (Force), applied via `run_onchange_after_config-kde-settings.sh.tmpl`.
- **Authority Hierarchy**: `.chezmoidata/kde.yaml` (single source of truth for KDE settings) > `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` (generic kwriteconfig6 runner) > live `~/.config/kwinrulesrc`.
- **Stop Conditions**: Stop and report if KWin rule format rejects the entries or if `config-kde-settings.sh.tmpl` validation fails on the row schema.

## Product Contract

### Summary

When applications or CLI commands (such as `op vault list`) trigger 1Password biometric or master password authentication, 1Password opens a compact dialog window. Under KDE Plasma Wayland, clicking another window moves focus and places the auth dialog behind other windows. Configuring a dedicated KWin window rule keeps the authentication dialog pinned on top while leaving the main 1Password application window unaffected.

### Problem Frame

The 1Password Electron application creates two types of windows:
1. **Authentication / Unlock dialog**: Window caption is exactly `1Password`, size is compact (~400x370 px), `wmclass` is `1password`.
2. **Main application window**: Window caption contains account and category delimiters (e.g. `HyperLapse — 모든 항목 — 1Password`), size is large (>1024x828 px), `wmclass` is `1password`.

Because both share the `1password` WMClass, an exact-title window rule (`title: 1Password`, `titlematch: 1`) is required to uniquely target the authentication prompt without altering the window management behavior of the main application.

### Requirements

- **R1**: `.chezmoidata/kde.yaml` must declare the `kwinrulesrc` setting rows in `kde.settings` for rule `1password-auth-above`:
  - `General:rules = 1password-auth-above` (type `string`)
  - `General:count = 1` (type `int`)
  - `1password-auth-above:Description = 1Password Auth Dialog Always on Top` (type `string`)
  - `1password-auth-above:wmclass = 1password` (type `string`)
  - `1password-auth-above:wmclassmatch = 1` (type `int`, exact match)
  - `1password-auth-above:title = 1Password` (type `string`)
  - `1password-auth-above:titlematch = 1` (type `int`, exact match)
  - `1password-auth-above:above = true` (type `bool`)
  - `1password-auth-above:aboverule = 3` (type `int`, force rule)
- **R2**: `.chezmoidata/kde.yaml` header rationale must document the `kwinrulesrc` rule purpose, matching fields, and runtime behavior.
- **R3**: `run_onchange_after_config-kde-settings.sh.tmpl` must render and validate all new `kwinrulesrc` rows cleanly without template errors.
- **R4**: When applied, KWin must enforce `keepAbove: true` on the 1Password authentication dialog while keeping `keepAbove: false` on the main 1Password window.

### Success Criteria

1. `.chezmoidata/kde.yaml` passes render-time validation with `chezmoi execute-template`.
2. `config-kde-settings.sh.tmpl` applies the rule rows via `kwriteconfig6`.
3. KWin window inspection confirms `1Password` auth dialog has `keepAbove: true` and main window retains normal window stacking.
4. `.ci/check-skip-declarations.sh` and `git diff --check` pass with no violations.

## Planning Contract

### Key Technical Decisions

- **KTD1: Data-driven KDE settings in `.chezmoidata/kde.yaml`**: Add pure manifest rows to `kde.settings` in `.chezmoidata/kde.yaml` rather than creating a separate script, adhering to the single source of truth architecture of `config-kde-settings.sh.tmpl`.
- **KTD2: Exact title matching (`titlematch: 1`)**: Matches `caption: 1Password` exactly. This discriminates the auth prompt from the main window (`<Account> — <Vault> — 1Password`) and Quick Access or Settings windows.
- **KTD3: Force rule (`aboverule: 3`)**: Ensures KWin actively forces the window to stay on top regardless of initial window placement or focus changes.

## Implementation Units

### U1. Add `kwinrulesrc` 1Password window rule to `.chezmoidata/kde.yaml`
- **Goal**: Document and declare the 1Password authentication dialog rule rows in `.chezmoidata/kde.yaml`.
- **Files**: `.chezmoidata/kde.yaml`
- **Verification**: Run `chezmoi execute-template` with scratch environment against `run_onchange_after_config-kde-settings.sh.tmpl`.

### U2. Verify KWin rule enforcement and live behavior
- **Goal**: Execute the rendered settings script or DBus reconfigure and verify window properties with test inspection script.
- **Files**: `.chezmoidata/kde.yaml`
- **Verification**: Trigger `op vault list` and verify `keepAbove: true` on the auth window.

### U3. CI and git cleanliness validation
- **Goal**: Verify repository sanity checks and CI gates.
- **Files**: Touch files
- **Verification**: Run `.ci/check-skip-declarations.sh` and `git diff --check`.

## Verification Contract

- Render test: `chezmoi execute-template < .chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl`
- KWin window verification: verify `keepAbove` property on live windows.
- CI script checks: `.ci/check-skip-declarations.sh`
- Diff check: `git diff --check`
