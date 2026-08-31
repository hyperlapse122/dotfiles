---
title: "Fix Ghostty Configuration Unknown Fields and Provide Catppuccin Theme"
date: "2026-08-31"
artifact_contract: "ce-unified-plan/v1"
artifact_readiness: "implementation-ready"
product_contract_source: "ce-plan"
execution: "code"
---

## Goal Capsule

- **Objective:** Eliminate Ghostty startup configuration validation errors by removing unrecognized legacy/fictitious configuration fields (`open-url-on-click`, `url-launcher`), correcting bell behavior configuration to `bell-features`, and provisioning the `catppuccin-mocha` theme file in managed dotfiles.
- **Means:** Update `dot_config/ghostty/config.tmpl` to remove invalid keys and configure `bell-features = no-audio,no-system,no-attention,no-title,no-border`; create `dot_config/ghostty/themes/catppuccin-mocha` with the authoritative Catppuccin Mocha color palette; verify with `ghostty +validate-config` and `chezmoi execute-template`.
- **Product Authority:** Dotfiles repository terminal emulator configuration (`dot_config/ghostty/config.tmpl` and `dot_config/ghostty/themes/catppuccin-mocha`).
- **Open Blockers:** None.

---

## Product Contract

### Summary

Ghostty 1.3.1 fails validation upon loading `~/.config/ghostty/config` due to three unknown configuration fields (`open-url-on-click`, `url-launcher`, `bell-action`) and a missing theme file `catppuccin-mocha` (as Fedora/Terra packages do not populate `/usr/share/ghostty/themes`). This change corrects the configuration syntax to match Ghostty 1.3.1's native schema and supplies the Catppuccin Mocha theme file directly in `~/.config/ghostty/themes/catppuccin-mocha`.

### Problem Frame

When launching Ghostty or running `ghostty +validate-config`, the following errors occur:
1. `config:54:open-url-on-click: unknown field`
2. `config:55:url-launcher: unknown field`
3. `config:59:bell-action: unknown field`
4. `theme "catppuccin-mocha" not found, tried path "/home/h82/.config/ghostty/themes/catppuccin-mocha"` and `/usr/share/ghostty/themes/catppuccin-mocha`.

In Ghostty 1.3.1:
- URL linking and interactive clicking are natively supported via `link-url = true` without auxiliary `open-url-on-click` or `url-launcher` directives.
- Bell silencing is configured via `bell-features = no-audio,no-system,no-attention,no-title,no-border` rather than `bell-action = none`.
- Ghostty searches `~/.config/ghostty/themes/<theme>` and `/usr/share/ghostty/themes/<theme>`. When the system package lacks bundled themes, providing `dot_config/ghostty/themes/catppuccin-mocha` guarantees theme availability across all environments.

### Key Decisions

- KD1. **Remove Unknown URL Directives** `(session-settled: user-approved — chosen over keeping non-functional fields: link-url=true natively enables URL detection and interaction)`
  - Governs R1.
- KD2. **Adopt Ghostty Standard Bell Directives** `(session-settled: user-approved — chosen over bell-action: bell-features=no-audio,no-system,no-attention,no-title,no-border silences terminal bell per Ghostty 1.3.1 schema)`
  - Governs R2.
- KD3. **Provision Managed Catppuccin Mocha Theme File** `(session-settled: user-approved — chosen over relying on system package /usr/share/ghostty/themes: deploying dot_config/ghostty/themes/catppuccin-mocha guarantees theme resolution on all Linux and macOS hosts)`
  - Governs R3.

### Requirements

- R1. `dot_config/ghostty/config.tmpl` removes `open-url-on-click` and `url-launcher` fields, keeping `link-url = true`.
- R2. `dot_config/ghostty/config.tmpl` replaces `bell-action = none` with `bell-features = no-audio,no-system,no-attention,no-title,no-border`.
- R3. Create `dot_config/ghostty/themes/catppuccin-mocha` containing the standard Catppuccin Mocha color palette (palette 0–15, background `#1e1e2e`, foreground `#cdd6f4`, cursor `#f5e0dc`, selection, and split dividers).
- R4. Preserve all existing font bindings (`.fonts.families.mono`, `.fonts.sizes.terminal`), keybindings, padding, and window opacity settings in `dot_config/ghostty/config.tmpl`.
- R5. Validation `ghostty +validate-config --config-file=<rendered-config>` succeeds with exit code 0 when evaluated against the target theme.

---

## Implementation Units

### U1. Create Ghostty Catppuccin Mocha Theme File
- **Target:** `dot_config/ghostty/themes/catppuccin-mocha`
- **Change:** Add the complete Catppuccin Mocha theme file defining the 16-color palette, background, foreground, cursor, and selection colors.
- **Acceptance:** File exists at `dot_config/ghostty/themes/catppuccin-mocha`.

### U2. Update Ghostty Configuration Template
- **Target:** `dot_config/ghostty/config.tmpl`
- **Change:**
  - Remove lines `open-url-on-click = true` and `url-launcher = auto`.
  - Replace `bell-action = none` with `bell-features = no-audio,no-system,no-attention,no-title,no-border`.
  - Retain `theme = catppuccin-mocha`, `link-url = true`, `scrollback-limit = 50000`, `confirm-close-surface = true`, and all other valid geometry/keybind settings.
- **Acceptance:** `chezmoi execute-template --source "$PWD" < dot_config/ghostty/config.tmpl` produces valid Ghostty configuration.

---

## Verification Contract

| Check | Command | Expected Outcome |
|---|---|---|
| Template Rendering | `env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < dot_config/ghostty/config.tmpl` | Renders clean configuration with Maple Mono font |
| Ghostty Config Validation | `ghostty +validate-config --config-file=<scratch>/target/.config/ghostty/config` | Exits 0 with no unknown field or missing theme warnings |
| Git Cleanliness | `git diff --check` | Clean diff with no whitespace errors |

## Definition of Done

1. `dot_config/ghostty/themes/catppuccin-mocha` is committed and deploys to `~/.config/ghostty/themes/catppuccin-mocha`.
2. `dot_config/ghostty/config.tmpl` contains valid Ghostty 1.3.1 configuration syntax.
3. `ghostty +validate-config` passes with zero errors and zero warnings.
