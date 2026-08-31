---
title: "Replace Kitty with Ghostty as Default Terminal Emulator"
date: "2026-08-31"
artifact_contract: "ce-unified-plan/v1"
artifact_readiness: "implementation-ready"
product_contract_source: "ce-brainstorm"
execution: "code"
---

## Goal Capsule

- **Objective:** Establish Ghostty as the sole, authoritative terminal emulator across Fedora Linux and macOS desktop environments, eliminating Kitty and its custom release-lock scripts while delivering centralized font coupling, visual transparency/blur effects, global quick-terminal access, native tab workflows, and tmux image passthrough.
- **Means:** Provision Ghostty via Fedora COPR (`scottames/ghostty`) and macOS Homebrew Cask, deploy managed configuration template `dot_config/ghostty/config.tmpl` linked to `fonts.yaml`, configure visual opacity/blur and dropdown quick-terminal hotkeys, update KDE and XDG default terminal registrations, and remove all legacy Kitty templates, release locks, and scripts (KD1, KD2).
- **Product Authority:** Dotfiles repository terminal emulator configuration. (Ubuntu Jetson arm64 provisioning remains unresolved pending upstream package delivery).
- **Open Blockers:** None.

---

## Product Contract

### Summary

Replace Kitty with Ghostty across all supported dotfiles desktop targets. On Fedora, Ghostty installs via the officially recommended `scottames/ghostty` COPR repository through DNF; on macOS, it installs as a Homebrew Cask. Configuration parity and visual enhancements are established via `dot_config/ghostty/config.tmpl`, binding font families and terminal font size to `.chezmoidata/fonts.yaml`, setting 128x24 window geometry, applying subtle background opacity with blur, enabling a global dropdown quick-terminal shortcut, preserving top tab workflows, and maintaining tmux Kitty graphics protocol passthrough. All legacy Kitty configuration files, provisioning scripts, release-lock definitions, and command manifests are completely pruned.

### Problem Frame

The dotfiles repository previously managed Kitty through a custom release-lock provisioning script (`run_onchange_before_kitty.sh.tmpl`) because Fedora distribution packages lagged upstream releases. Ghostty is a modern, fast, cross-platform terminal emulator that natively implements the Kitty graphics protocol, client-side/server-side window decorations, background blur/opacity, global quick-terminal (dropdown/Quake mode), and native tabs. The community `scottames/ghostty` COPR provides rapid tracking of official Ghostty releases (such as v1.3.1) directly integrated with native DNF package management, eliminating the carrying cost of maintaining custom tarball extraction scripts and release-lock registry entries for Kitty while offering richer native desktop integration.

### Key Decisions

- KD1. **Full Replacement of Kitty** `(session-settled: user-directed — chosen over 점진적 보존: Kitty 설정을 보존하지 않고 Ghostty로 단일화)`
  - Rationale: A single authoritative terminal emulator simplifies dotfiles maintenance and avoids duplicate configuration drift.
  - Governs R1, R6, R7, R8, R9, R10, R11, R12, R13, R14.
- KD2. **Fedora COPR Packaging Priority** `(session-settled: user-directed — chosen over 정적 바이너리 잠금: scottames/ghostty COPR로 신속한 최신 릴리즈 추적 및 DNF 통합 관리)`
  - Rationale: The `scottames/ghostty` COPR is the officially recommended Fedora installation path and tracks upstream releases promptly without custom build/extract scripts.
  - Governs R2, R3.
- KD3. **macOS and Ubuntu Platform Disposition**
  - Rationale: macOS provisions Ghostty cleanly through Homebrew Cask, while Ubuntu Jetson (arm64) is tracked as `unresolved` in package manifests until an official or proven package-delivery path is established.
  - Governs R4, R5.
- KD4. **Centralized Font Coupling and Visual Styling** `(session-settled: user-directed — chosen over 기본 불투명/고정 테마: fonts.yaml 연동과 함께 반투명/블러 효과 적용)`
  - Rationale: Terminal font family and size render from `.chezmoidata/fonts.yaml` (`fonts.families.mono` and `fonts.sizes.terminal`), styled with subtle background opacity and blur for enhanced desktop aesthetics.
  - Governs R6, R7.
- KD5. **Global Quick-Terminal Enablement** `(session-settled: user-directed — chosen over 표준 창 전용 모드: 글로벌 드롭다운 퀵 터미널 단축키 활성화)`
  - Rationale: A global toggle shortcut provides instant terminal scratchpad access without disrupting active desktop windows.
  - Governs R8.
- KD6. **Default Upstream Behavior for Auxiliary Controls** `(session-settled: user-directed — chosen over 커스텀 커서/닫기 동작 오버라이드: 커서 모양 및 종료 확인은 Ghostty 기본값 준수)`
  - Rationale: Minimizing unnecessary overrides keeps the configuration maintainable and aligned with upstream best practices.
  - Governs R7.

### Requirements

**Provisioning and Package Management**
- R1. Declare `ghosttyTerminal` package metadata in `.chezmoidata/packages.yaml` replacing `kittyTerminal`.
- R2. Declare `scottames/ghostty` in `.chezmoidata/packages.yaml` under `fedora.coprs` to enable the repository on Fedora systems.
- R3. Add `ghostty` to `fedora.kdePackages` and `fedora.gnomePackages` in `.chezmoidata/packages.yaml`.
- R4. Declare Ghostty Homebrew cask in `.chezmoidata/packages.yaml` for macOS targets.
- R5. Track `ghosttyTerminal` on Ubuntu arm64 with disposition `unresolved` and a documented reason.

**Configuration, Visuals, and Desktop Integration**
- R6. Create `dot_config/ghostty/config.tmpl` referencing `.chezmoidata/fonts.yaml` for `font-family` (`fonts.families.mono`) and `font-size` (`fonts.sizes.terminal`).
- R7. Configure Ghostty visual and window settings in `dot_config/ghostty/config.tmpl` for window geometry (128 columns by 24 rows), background opacity (`background-opacity = 0.9`), background blur (`background-blur = true`), window decorations (`auto`), working directory inheritance (`window-inherit-working-directory = true`), tab navigation keybindings (`ctrl+shift+t` new tab, `ctrl+page_up`/`ctrl+page_down` tab switching), and clipboard behavior (`copy-on-select = clipboard`), while retaining Ghostty upstream defaults for cursor style and surface close confirmation.
- R8. Configure global quick-terminal support (`quick-terminal-position = top` and `keybind = global:ctrl+grave_accent=toggle_quick_terminal`) in `dot_config/ghostty/config.tmpl`.
- R9. Update `.chezmoidata/kde.yaml` to set `kdeglobals` `[General] TerminalApplication = ghostty`.
- R10. Deploy `dot_local/share/xdg-terminals/ghostty.desktop` and register Ghostty as the default XDG terminal provider.

**Deprecation, Removal and Verification**
- R11. Delete `.chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl`, `dot_config/kitty/`, `dot_local/share/applications/kitty.desktop.tmpl`, and `dot_local/share/xdg-terminals/kitty.desktop`.
- R12. Remove the `kitty` release definition from `packages/release-lock/src/registry.ts` and update `.chezmoidata/releases.json`.
- R13. Remove the `kitty` command tree definition from `.chezmoidata/commands.yaml`.
- R14. Update repository CI tests (`.ci/test-package-ownership.sh`, `.ci/test-command-external-render.sh`, `.ci/test-tmux-kitty-passthrough.sh`, `.ci/test-chezmoiignore-script-paths.sh`) to verify Ghostty package ownership and clean template execution.

### Key Flows

- F1. Fresh Fedora Host Provisioning
  - **Trigger:** Chezmoi apply executes on a fresh or updated Fedora host.
  - **Actors:** Chezmoi engine, DNF package manager.
  - **Steps:** DNF enables `scottames/ghostty` COPR, installs `ghostty` RPM, renders `~/.config/ghostty/config` from template with fonts from `fonts.yaml`, applies visual opacity/blur and quick-terminal settings, sets KDE/XDG terminal defaults, and prunes old Kitty scripts.
  - **Outcome:** Ghostty is immediately available as the system default terminal emulator with configured typography, aesthetics, and geometry.
  - **Covered by:** R1, R2, R3, R6, R7, R8, R9, R10, R11.

- F2. Terminal Launch, Quick-Terminal, and Multiplexer Passthrough
  - **Trigger:** User launches Ghostty (normal window or global quick-terminal hotkey) and runs terminal applications or tmux sessions.
  - **Actors:** User, Ghostty, Tmux, Oh-My-Pi / CLI tools.
  - **Steps:** Ghostty starts with 128x24 text grid, transparent/blurred background, inherits working directories across new tabs (`ctrl+shift+t`), toggles dropdown quick-terminal via global hotkey, and renders Kitty graphics protocol payloads (including tmux passthrough via `dot_config/tmux/tmux.conf`).
  - **Outcome:** Pixel-accurate image rendering, seamless dropdown access, and consistent tab navigation.
  - **Covered by:** R6, R7, R8, R14.

### Acceptance Examples

- AE1. Package Declaration and COPR Registration
  - **Given:** `.chezmoidata/packages.yaml` is parsed during chezmoi execution on Fedora.
  - **When:** Package reconciliation runs.
  - **Then:** `scottames/ghostty` is present in COPR list, `ghostty` is listed under desktop packages, and `kittyTerminal` is absent.
  - **Covered by:** R1, R2, R3.

- AE2. Configuration, Visual Styling, and Quick-Terminal Parity
  - **Given:** `dot_config/ghostty/config.tmpl` is rendered with `fonts.yaml` containing `mono: "JetBrainsMono Nerd Font"` and `terminal: 12`.
  - **When:** `chezmoi execute-template` renders the configuration.
  - **Then:** The output contains `font-family = JetBrainsMono Nerd Font`, `font-size = 12`, `window-width = 128`, `window-height = 24`, `background-opacity = 0.9`, `background-blur = true`, `quick-terminal-position = top`, and tab navigation keybindings.
  - **Covered by:** R6, R7, R8.

- AE3. Desktop Integration
  - **Given:** KDE Plasma settings are applied from `.chezmoidata/kde.yaml`.
  - **When:** `kdeglobals` is inspected.
  - **Then:** `[General] TerminalApplication` equals `ghostty`, and `xdg-terminal-exec` resolves to Ghostty.
  - **Covered by:** R9, R10.

- AE4. Clean Kitty Purge
  - **Given:** The migration changes are applied.
  - **When:** Repository search is performed for managed Kitty artifacts.
  - **Then:** No `dot_config/kitty`, `run_onchange_before_kitty.sh.tmpl`, or `kitty.desktop` files exist, and release-lock tests pass without Kitty.
  - **Covered by:** R11, R12, R13, R14.

### Scope Boundaries

- **Deferred for later:**
  - Automated compilation pipeline for Ghostty on Ubuntu Jetson (arm64); disposition stays `unresolved` until an upstream package is validated.
  - Alternative terminal emulators (WezTerm, Alacritty) configuration updates.
- **Outside this product's identity:**
  - Upstream Ghostty source modifications or packaging repository maintenance.
  - Custom shell completions or prompt themes outside managed Zsh.

### Outstanding Questions

- None.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **DNF/COPR Package Ownership for Ghostty** (KD2, KD3)
  - Ghostty is managed via `.chezmoidata/packages.yaml` with `owner: dnf`, `source: copr`, and `copr: scottames/ghostty` on Fedora, and `owner: homebrew`, `kind: cask` on macOS. This replaces the `releaseLock` mechanism used by Kitty, removing the need for a custom download script in `00-tools`.
- KTD2. **Ghostty Native Configuration Architecture** (KD4, KD5, KD6)
  - `dot_config/ghostty/config.tmpl` renders standard `key = value` Ghostty syntax. Typography parameters (`font-family`, `font-size`) are rendered via Go template directives from `.chezmoidata/fonts.yaml`, ensuring single-point updates across all desktop and editor targets.
- KTD3. **XDG Terminal Registration and Plasma Handshake** (KD1)
  - Default terminal preference in KDE Plasma is set in `kdeglobals` (`TerminalApplication = ghostty`), and system-wide CLI invocations via `xdg-terminal-exec` resolve to `dot_local/share/xdg-terminals/ghostty.desktop`.
- KTD4. **Release-Lock Registry and Command Manifest Cleanup** (KD1)
  - Kitty is removed from `packages/release-lock/src/registry.ts`, `.chezmoidata/releases.json`, and `.chezmoidata/commands.yaml`. Because Ghostty is packaged as an RPM/Homebrew binary, its executable lives in system PATH (`/usr/bin/ghostty` or `/opt/homebrew/bin/ghostty`), requiring no custom symlink producer in `commands.yaml`.

---

## Implementation Units

### U1. Package Manifests & Command Registry Cutover
- **Goal:** Replace Kitty declarations with Ghostty across package manifests, COPR repositories, desktop package groups, and command definitions.
- **Requirements:** R1, R2, R3, R4, R5, R12, R13
- **Files:**
  - `.chezmoidata/packages.yaml`
  - `.chezmoidata/commands.yaml`
  - `packages/release-lock/src/registry.ts`
  - `packages/release-lock/test/registry.test.ts`
  - `.chezmoidata/releases.json`
- **Approach:**
  1. In `.chezmoidata/packages.yaml`, replace `kittyTerminal` under `managedPackages` with `ghosttyTerminal` (Fedora: dnf/copr `scottames/ghostty`, macOS: homebrew cask `ghostty`, Ubuntu: unresolved).
  2. Add `scottames/ghostty` to `fedora.coprs` list.
  3. Replace `kitty` with `ghostty` in `fedora.kdePackages` and `fedora.gnomePackages`.
  4. In `.chezmoidata/commands.yaml`, remove the `kitty` command tree entry.
  5. In `packages/release-lock/src/registry.ts` and its test, remove the `kitty` definition. Remove `kitty` key from `.chezmoidata/releases.json`.
- **Verification:** Run `pnpm --filter release-lock test` and execute `.ci/test-package-ownership.sh`.

### U2. Ghostty Managed Configuration Template
- **Goal:** Create `dot_config/ghostty/config.tmpl` with font coupling, visual transparency/blur, quick-terminal, geometry, and keybindings.
- **Requirements:** R6, R7, R8
- **Files:**
  - `dot_config/ghostty/config.tmpl`
- **Approach:**
  1. Author `dot_config/ghostty/config.tmpl` with Go template comment header documenting `.chezmoidata/fonts.yaml` binding.
  2. Map `font-family = {{ .fonts.families.mono }}` and `font-size = {{ .fonts.sizes.terminal }}`.
  3. Add `window-width = 128`, `window-height = 24`, `background-opacity = 0.9`, `background-blur = true`, `window-decoration = auto`.
  4. Enable `window-inherit-working-directory = true` and `copy-on-select = clipboard`.
  5. Configure keybindings: `keybind = ctrl+shift+t=new_tab`, `keybind = ctrl+page_up=previous_tab`, `keybind = ctrl+page_down=next_tab`.
  6. Enable quick-terminal: `quick-terminal-position = top` and `keybind = global:ctrl+grave_accent=toggle_quick_terminal`.
- **Verification:** Execute `chezmoi execute-template < dot_config/ghostty/config.tmpl` and verify valid Ghostty syntax and resolved font names.

### U3. Desktop Environment & XDG Integration
- **Goal:** Set Ghostty as default terminal in KDE Plasma and XDG terminal dispatcher.
- **Requirements:** R9, R10
- **Files:**
  - `.chezmoidata/kde.yaml`
  - `dot_local/share/xdg-terminals/ghostty.desktop`
- **Approach:**
  1. In `.chezmoidata/kde.yaml`, update `TerminalApplication` entry in `General` group from `kitty` to `ghostty`.
  2. Create `dot_local/share/xdg-terminals/ghostty.desktop` defining `Exec=ghostty`, `Name=Ghostty`, `Type=Application`.
- **Verification:** Verify `kde.yaml` parses cleanly and `ghostty.desktop` passes desktop-file validation if available.

### U4. Legacy Kitty Artifact Pruning
- **Goal:** Delete all residual Kitty templates, provisioning scripts, and desktop entries.
- **Requirements:** R10, R11
- **Files:**
  - `.chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl` (delete)
  - `dot_config/kitty/kitty.conf.tmpl` (delete)
  - `dot_local/share/applications/kitty.desktop.tmpl` (delete)
  - `dot_local/share/xdg-terminals/kitty.desktop` (delete)
- **Approach:**
  1. Remove `.chezmoiscripts/00-tools/run_onchange_before_kitty.sh.tmpl`.
  2. Remove `dot_config/kitty/kitty.conf.tmpl` and `dot_config/kitty` directory.
  3. Remove `dot_local/share/applications/kitty.desktop.tmpl` and `dot_local/share/xdg-terminals/kitty.desktop`.
- **Verification:** `git status` confirms complete deletion of all Kitty source files.

### U5. CI Test Suite & Regression Verification
- **Goal:** Update CI test scripts and verify repository integrity.
- **Requirements:** R14
- **Files:**
  - `.ci/test-package-ownership.sh`
  - `.ci/test-command-external-render.sh`
  - `.ci/test-chezmoiignore-script-paths.sh`
  - `.ci/test-tmux-kitty-passthrough.sh`
- **Approach:**
  1. In `.ci/test-package-ownership.sh`, update checks from `kitty` / `kittyTerminal` to `ghostty` / `ghosttyTerminal`.
  2. In `.ci/test-chezmoiignore-script-paths.sh` and `.ci/test-command-external-render.sh`, remove references to deleted `run_onchange_before_kitty.sh.tmpl`.
  3. Run full CI test suite locally to verify green status.
- **Verification:** Execute `.ci/test-package-ownership.sh`, `.ci/test-tmux-kitty-passthrough.sh`, `pnpm --filter release-lock test`, and chezmoi template validation.

---

## Verification Contract

| Test Suite / Script | Target | Scope |
|---|---|---|
| `pnpm --filter release-lock test` | `packages/release-lock/test/registry.test.ts` | Verify release-lock registry tests pass without Kitty |
| `.ci/test-package-ownership.sh` | `.chezmoidata/packages.yaml` | Verify package ownership rules and Ghostty COPR / Cask assertions |
| `.ci/test-tmux-kitty-passthrough.sh` | `dot_config/tmux/tmux.conf` | Verify tmux image protocol passthrough configuration |
| `chezmoi execute-template < dot_config/ghostty/config.tmpl` | `dot_config/ghostty/config.tmpl` | Verify Ghostty configuration renders cleanly with fonts from `fonts.yaml` |
| `git diff --check` | Working tree | Verify clean syntax, no whitespace errors, no unresolved markers |

---

## Definition of Done

- All Implementation Units (U1 through U5) are implemented and verified.
- Ghostty is declared in `.chezmoidata/packages.yaml` (`scottames/ghostty` COPR for Fedora, Homebrew Cask for macOS) and `kittyTerminal` is removed.
- `dot_config/ghostty/config.tmpl` is created with font binding, 128x24 window geometry, background opacity/blur, quick-terminal, and tab keybindings.
- `.chezmoidata/kde.yaml` sets `TerminalApplication = ghostty` and `xdg-terminals/ghostty.desktop` is present.
- All Kitty configuration files, provisioning scripts, release-lock registry entries, and commands are pruned.
- CI tests (`test-package-ownership.sh`, `test-tmux-kitty-passthrough.sh`, `release-lock test`) pass with zero errors.
- Dead-end or temporary migration code is removed.
