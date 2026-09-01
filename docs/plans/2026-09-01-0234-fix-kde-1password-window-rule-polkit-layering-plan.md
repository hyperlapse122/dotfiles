---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Bugfix: Fix 1Password Always-On-Top Window Rule and Polkit Layering in KWin

## Goal Capsule

- **Objective**: Ensure only 1Password authentication/unlock dialogs stay on top without pinning the main 1Password window, and ensure Polkit authentication agent dialogs remain layered on top of all windows (including 1Password dialogs) under KDE Plasma 6.
- **Means**:
  1. Restrict the `1password-auth-above` KWin window rule in `.chezmoidata/kde.yaml` to dialog window types (`types = 32`, `typesrule = 2`) so normal application windows (`types = 1`) remain in the normal window layer.
  2. Add a new `polkit-auth-above` KWin window rule in `.chezmoidata/kde.yaml` targeting `wmclass = polkit-kde-authentication-agent-1` (`wmclassmatch = 2`) with `above = true` (`aboverule = 3`) and `types = 32`.
  3. Update `kwinrulesrc` `[General]` configuration to register both rules (`rules = 1password-auth-above,polkit-auth-above`, `count = 2`).
  4. Update `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` `$valueRe` regex to permit comma `,` for delimited rule lists.
- **Authority Hierarchy**: `.chezmoidata/kde.yaml` (single source of truth for KDE settings) > `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` (generic kwriteconfig6 runner) > live `~/.config/kwinrulesrc`.
- **Stop Conditions**: Stop if `config-kde-settings.sh.tmpl` render validation fails or if `kwinrulesrc` schema rejects the rule keys.

## Product Contract

### Summary

In issue #328, the current KWin rule `1password-auth-above` matches any window with `wmclass: 1password` and title `1Password` without filtering by window type. Because the 1Password main window also uses title `1Password` and WMClass `1password`, the main window is incorrectly forced to the Always-on-Top layer (`above: true`). Furthermore, when Polkit system authentication dialogs appear, they open in the Normal layer and are obscured behind 1Password's forced Above layer.

This fix constrains 1Password keep-above matching specifically to Dialog windows (`types: 32`), keeping the main window in standard window stacking, and adds a dedicated keep-above rule for Polkit authentication dialogs (`polkit-kde-authentication-agent-1`) so system auth prompts always stay visible above all application windows.

### Problem Frame

1. **All 1Password windows forced to Always-on-Top**: The existing rule `1password-auth-above` specifies `title: 1Password` (`titlematch: 1`) and `wmclass: 1password` (`wmclassmatch: 1`) with no `types` filter. The 1Password main window shares the `1password` class and title `1Password` (e.g. on start or lock screen), causing KWin to force the main window above all other desktop applications.
2. **Polkit authentication dialog hidden behind 1Password**: Polkit authentication agent (`org.kde.polkit-kde-authentication-agent-1` / `polkit-kde-authentication-agent-1`) dialogs default to the normal layer. When an auth action triggers while 1Password is in the Above layer, Polkit appears behind 1Password.

### Requirements

- **R1**: `.chezmoidata/kde.yaml` must update `1password-auth-above` with `types: 32` (Dialog window) and `typesrule: 2` (Force/Apply).
- **R2**: `.chezmoidata/kde.yaml` must declare `polkit-auth-above` KWin window rule:
  - `General:rules = 1password-auth-above,polkit-auth-above`
  - `General:count = 2`
  - `polkit-auth-above:Description = Polkit Auth Dialog Always on Top`
  - `polkit-auth-above:wmclass = polkit-kde-authentication-agent-1`
  - `polkit-auth-above:wmclassmatch = 2` (Substring match, covering both Wayland appId and X11 wmclass)
  - `polkit-auth-above:types = 32` (type int, Dialog window)
  - `polkit-auth-above:typesrule = 2` (type int)
  - `polkit-auth-above:above = true` (type bool)
  - `polkit-auth-above:aboverule = 3` (type int, Force)
- **R3**: `.chezmoidata/kde.yaml` header documentation must accurately document the `kwinrulesrc` settings, window types, and stacking rationale.
- **R4**: `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` `$valueRe` must allow `,` to support comma-separated `rules` lists.
- **R5**: Template execution via `chezmoi execute-template` must render cleanly and validate without errors.

### Success Criteria

1. `.chezmoidata/kde.yaml` renders cleanly through `run_onchange_after_config-kde-settings.sh.tmpl`.
2. `kwinrulesrc` contains properly configured `1password-auth-above` and `polkit-auth-above` rules.
3. 1Password main window (`types = 1`) is excluded from Always-on-Top while 1Password dialogs (`types = 32`) match.
4. Polkit authentication agent dialogs (`polkit-kde-authentication-agent-1`) are forced Always-on-Top.
5. All repo checks (`.ci/check-skip-declarations.sh`, `git diff --check`) pass.

## Planning Contract

### Key Technical Decisions

- **KTD1: Window type filtering via `types = 32` (Dialog)**: Restricts the rule to `NET::Dialog` (bitmask 32), ensuring normal application windows (`NET::Normal`, bitmask 1) are never pinned on top.
- **KTD2: Substring WMClass match for Polkit (`wmclassmatch: 2`)**: `polkit-kde-authentication-agent-1` matches both Wayland appId `org.kde.polkit-kde-authentication-agent-1` and X11 WMClass `polkit-kde-authentication-agent-1`.
- **KTD3: Comma support in `config-kde-settings.sh.tmpl` `$valueRe`**: Permits `,` in value validation regex `^[A-Za-z0-9 _./+,-]+$` so multi-rule lists (`1password-auth-above,polkit-auth-above`) validate cleanly at render time.

## Implementation Units

### U1. Update `config-kde-settings.sh.tmpl` to allow commas in values
- **Goal**: Allow comma-delimited strings in `valueRe` validation regex.
- **Files**: `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl`
- **Verification**: Run template execution test.

### U2. Update `.chezmoidata/kde.yaml` window rules and documentation
- **Goal**: Update `1password-auth-above` with dialog type restriction, add `polkit-auth-above` rule, update `General:rules` and `General:count`, and update header comments.
- **Files**: `.chezmoidata/kde.yaml`
- **Verification**: Run `chezmoi execute-template` with scratch environment against `run_onchange_after_config-kde-settings.sh.tmpl`.

### U3. Validation and CI cleanliness
- **Goal**: Verify rendering across templates and verify CI scripts.
- **Files**: Repo workspace
- **Verification**: Run `.ci/check-skip-declarations.sh` and `git diff --check`.

## Verification Contract

- Render test: `chezmoi execute-template < .chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl`
- CI skip declarations: `.ci/check-skip-declarations.sh`
- Diff check: `git diff --check`
