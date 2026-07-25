---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: Add kitty terminal + default-terminal for GNOME & KDE (Linux)
date: 2026-07-25
---

# Implementation Plan

## Goal
Install the kitty terminal emulator on Linux (Fedora + Ubuntu) and make it the
default terminal for both KDE Plasma and GNOME, entirely through the repo's
data-driven conventions (package data, the `kde.yaml` manifest, and managed
`dot_config/` files) — **no new runtime script**.

## Context / Problem Frame
- `kitty` is absent everywhere in the repo (grep across `.chezmoidata/` +
  `.chezmoiscripts/` returns zero matches); no "default terminal" exists for
  either desktop.
- GNOME's only terminal tunable today is the Ptyxis *palette*
  (`.chezmoidata/gnome.yaml` → `gnome.terminal.palette`, applied by
  `run_onchange_after_config-gnome-terminal-palette.sh.tmpl`); Ptyxis is the
  default terminal on Ubuntu 26.04 / Fedora 44.
- KDE settings come from the `.chezmoidata/kde.yaml` kwriteconfig6 row manifest,
  applied by `run_onchange_after_config-kde-settings.sh.tmpl` (render-time
  validated; a data edit re-triggers the script by itself).
- The existing "default application" precedent is
  `.chezmoiscripts/30-linux/run_onchange_after_set-default-browser.sh.tmpl`
  (per-user, idempotent, soft-skip guards) — but it needs *runtime*
  `xdg-settings`/`xdg-mime` calls. The terminal default is expressible as
  *static* config + one manifest row, which is strictly more data-driven.

## Requirements (traceable)
- **R1** kitty is installed on Fedora and Ubuntu whenever a desktop (KDE or
  GNOME) is present.
- **R2** kitty is the default terminal on KDE Plasma 6.
- **R3** kitty is the default terminal on GNOME (Ubuntu 26.04 / Fedora 44,
  Ptyxis era) for the apps/portal consumers that resolve a default terminal.
- **R4** a minimal managed kitty config exists at `~/.config/kitty/kitty.conf`.
- **R5** all changes are data-driven / managed files; verification never deploys
  live `$HOME`.

### Scope boundaries
- **In scope:** `packages.yaml` (3 desktop-gated lists), `kde.yaml` (1 row), 2
  new managed `dot_config/` files, branch rename before push.
- **Out of scope:** macOS/Windows (kitty is Linux-only here); headless servers
  (kitty is desktop-gated); replacing Ptyxis; a rich kitty theme; changing the
  login shell (zsh already set via `run_onchange_after_chsh-zsh.sh.tmpl`);
  `gnome.yaml` (no change needed — see KTD-3); a new `run_onchange` script
  (rejected — see KTD-4).

## Key Technical Decisions (KTDs)
- **KTD-1 — package gating (not unconditional).** Gate `kitty` +
  `xdg-terminal-exec` on the desktop package groups: add to
  `packages.linux.fedora.kdePackages`, `packages.linux.fedora.gnomePackages`,
  and `packages.linux.ubuntu.gnomePackages`. *Rejected:* unconditional in
  `packages:` (matches the `tmux` precedent but pulls GUI/OpenGL deps onto
  headless hosts and breaks the repo convention that every GUI/desktop app is
  desktop-gated). *Reason:* all existing GUI apps here are desktop-gated;
  containers skip package provisioning entirely (`is_container`); the
  gnome/kde-list duplication is the accepted cost of the single-fact gate model
  (no OR in the gate grammar).

- **KTD-2 — KDE default terminal = one `kde.yaml` row.** Set
  `kdeglobals [General] TerminalApplication = kitty` via a single manifest row,
  applied by the existing `config-kde-settings` runner (`kwriteconfig6`).
  *Justification:* `TerminalApplication` in `[General]` is the key Plasma's
  Default-Applications KCM writes and that KIO / "Open Terminal Here" / KRunner
  honor across Plasma 5 & 6; it's a pure data edit with zero new script.
  *Fallback* (only if validation shows Plasma 6.x ignores it): also drop
  `~/.config/xdg-terminals/kitty.desktop` (xdg-terminal-exec), honored by
  Plasma 6.2+.

- **KTD-3 — GNOME default terminal = `xdg-terminal-exec` drop-in.** Install the
  `xdg-terminal-exec` package and manage
  `~/.config/xdg-terminals/kitty.desktop` (per-user drop-in declaring kitty as
  the terminal provider). *Justification:* per-user (no `sudo` — matches the
  default-browser philosophy); cross-distro (Ubuntu + Fedora); honored by GNOME's
  Terminal portal and the freedesktop default-terminal resolver; the only modern
  lever after GNOME removed `org.gnome.desktop.default-applications.terminal`
  (gone since GNOME 42 — must NOT be relied on). *Rejected:*
  `update-alternatives` (Ubuntu/Debian-only, system-wide/`sudo`); the removed
  gsettings key (forbidden). `gnome.yaml` is **not** modified — the GNOME
  mechanism is a static managed file, not a gsettings tunable, so there is
  nothing to parameterize there; the Ptyxis-palette script stays untouched.

- **KTD-4 — no new default-terminal script.** Unlike `set-default-browser`
  (runtime `xdg-settings`/`xdg-mime`), the terminal default is static config
  (xdg-terminals drop-in) + a manifest row (`kde.yaml`) + package data, all
  deployed/applied by *existing* mechanisms. A new `run_onchange` script would
  duplicate them. `set-default-browser` stays as-is.

- **KTD-5 — minimal, self-contained `kitty.conf`.** Conservative defaults only;
  does **not** couple to `fonts.yaml`. kitty inherits `$SHELL` (zsh) so no
  `shell` directive is needed.

## Assumptions
- `xdg-terminal-exec` is packaged under that exact name on Fedora and on Ubuntu
  26.04 (universe). *Validate availability.*
- `kitty` is packaged under that name on both; Ubuntu's archive version may lag
  upstream — acceptable for a default-terminal use (the archive package is the
  convention-consistent choice, matching how all other GUI apps install here).
- Plasma 6 honors `kdeglobals [General] TerminalApplication`. *Validate;*
  fallback in KTD-2.
- `xdg-terminal-exec` resolves the user-config-dir drop-in
  (`~/.config/xdg-terminals/`) with highest precedence, making kitty default.
  *Validate exact precedence.*
- The new `dot_config/` files deploy harmlessly inside containers (kitty is not
  installed there); matches the fcitx5-config-in-container precedent, so
  `.chezmoiignore` is left unchanged.

## Tasks (Implementation Units)

### U1 — Add kitty + xdg-terminal-exec packages (desktop-gated)
- **File:** `.chezmoidata/packages.yaml`
- **Edits:**
  - `packages.linux.fedora.kdePackages` (~line 335): add `kitty` and
    `xdg-terminal-exec` (with `# …` trailing comments matching the file style).
  - `packages.linux.fedora.gnomePackages` (~line 348): add the same two.
  - `packages.linux.ubuntu.gnomePackages` (~line 656): add the same two.
- **Acceptance:** rendered Fedora/Ubuntu installers include both packages in the
  desktop-gated arrays; render-time validation passes.
- **Test scenarios:**
  1. Render `20-linux-fedora/run_onchange_before_fedora.sh.tmpl` → `kitty` and
     `xdg-terminal-exec` appear under the `kdePackages` and `gnomePackages`
     gated arrays.
  2. Render `40-linux-ubuntu/run_onchange_before_ubuntu.sh.tmpl` → both appear
     under the `gnomePackages` gated array.
  3. `chezmoi archive --exclude=encrypted,externals,scripts` still builds.

### U2 — KDE default terminal via one `kde.yaml` row
- **File:** `.chezmoidata/kde.yaml`
- **Edit:** append one row to `kde.settings`, with a `#` rationale comment block
  matching the file's per-row convention:
  `- { file: kdeglobals, group: General, key: TerminalApplication, type: string, value: kitty }`
- **Static validation (confirmed during planning):** `kitty` matches the
  runner's `valueRe` `^[A-Za-z0-9 _./+-]+$`; `General`/`TerminalApplication`
  match `fieldRe` `^[A-Za-z0-9_.-]+$`; no colon in value → the row **will**
  pass render-time validation.
- **Acceptance:** rendered `config-kde-settings` script contains the row.
- **Test scenarios:**
  1. `chezmoi execute-template < …/run_onchange_after_config-kde-settings.sh.tmpl`
     exits 0 (no validation `fail`) and the rendered array contains the line
     `kdeglobals:General:TerminalApplication:string:kitty`.

### U3 — GNOME default terminal via xdg-terminal-exec drop-in
- **File:** `dot_local/share/xdg-terminals/kitty.desktop` (**NEW** →
  `~/.local/share/xdg-terminals/kitty.desktop` — XDG_DATA_HOME, the only path
  xdg-terminal-exec scans; corrected from `dot_config/` during review followup)
- **Content (minimal):** a valid `.desktop` declaring kitty as an
  `xdg-terminal-exec` terminal provider — `Type=Application`, `Name=kitty`,
  `Exec=kitty`, `Icon=kitty`, `NoDisplay=true` — with a header comment stating
  the precedence assumption (user-config-dir wins) and that
  `xdg-terminal-exec` must be installed (U1) for it to take effect.
- **Acceptance:** `chezmoi archive` deploys `.config/xdg-terminals/kitty.desktop`.
- **Test scenarios:**
  1. Archive includes the file at the expected target path.
  2. `desktop-file-validate` (if available) reports no critical errors.

### U4 — Minimal kitty config
- **File:** `dot_config/kitty/kitty.conf` (**NEW** → `~/.config/kitty/kitty.conf`)
- **Content:** conservative self-contained defaults (e.g. `font_size`,
  `hide_window_decorations yes`, `copy_on_select clipboard`) + a header comment.
  No `fonts.yaml` coupling, no `shell` directive (inherits `$SHELL`=zsh), no
  `include` of absent files.
- **Acceptance:** archive deploys `.config/kitty/kitty.conf`.
- **Test scenarios:**
  1. Archive includes the file.
  2. Content is valid kitty.conf syntax (parses; no missing includes).

### U5 — Branch rename (non-code, shipping step)
- Current branch `persians` is a non-descriptive worktree-derived name. Per
  AGENTS.md it MUST be renamed to a work-descriptive Git-Flow slug
  (`feature/add-kitty-default-terminal-linux`) before first push. Owned by the
  shipping/commit-push step — **not** an implementation unit.

## Files to Modify
- `.chezmoidata/packages.yaml` — add `kitty` + `xdg-terminal-exec` to
  `fedora.kdePackages`, `fedora.gnomePackages`, `ubuntu.gnomePackages` (U1).
- `.chezmoidata/kde.yaml` — add one `kdeglobals [General] TerminalApplication=kitty`
  row (U2).

## New Files
- `dot_local/share/xdg-terminals/kitty.desktop` — xdg-terminal-exec provider
  drop-in (GNOME default terminal) (U3).
- `dot_config/kitty/kitty.conf` — minimal managed kitty config (U4).

## Dependencies
- U1, U2, U3, U4 are mutually independent and may land in any order.
- **U1 ⊃ U3 runtime coupling:** the `xdg-terminal-exec` package (U1) is a
  runtime dependency for the U3 drop-in to take effect on GNOME — both must ship
  together.
- U5 (rename) is last, at push time.

## Verification Contract (never deploy live `$HOME`)
Per AGENTS.md: per-user scratch dir, stub `op`, empty config, throwaway
destination, `--source "$PWD"`. The planner cannot run these (no shell tool) —
they are for the implementer (`ce-work`).

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
# Render the changed installers + the KDE runner through the stub:
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/40-linux-ubuntu/run_onchange_before_ubuntu.sh.tmpl
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < .chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl
# Target-tree check (archive omits scripts — compare rendered scripts separately; state that blind spot):
chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" archive --exclude=encrypted,externals,scripts
```
- `git diff --check`, `git status` — confirm only the 4 files changed.
- CI on push: `render-dotfiles.yml` (shellcheck on **rendered** scripts —
  validates the kde row renders into valid bash and the installers lint clean)
  + `ci.yml`. Watch both to terminal success.
- **NO** live `chezmoi apply`, **NO** real `gsettings`/`kwriteconfig6` against
  the host as "verification".
- **Behavior-change signal:** config/rendering-only; this repo has no unit-test
  layer for chezmoi data. *Existing tests inspected:* none apply. *Tests added:*
  none (none exist for this layer — the repo's bar for data/script changes is
  render + archive + CI shellcheck). *Characterization:* N/A.

## Definition of Done
- `packages.yaml` + `kde.yaml` edited; the 2 `dot_config/` files created.
- Render-check passes (kde row validates; installers include the packages).
- Archive confirms the 2 new managed files deploy to the right paths.
- `git diff --check` clean; diff limited to the 4 files.
- Branch renamed to `feature/add-kitty-default-terminal-linux` before push.
- CI (`render-dotfiles.yml` + `ci.yml`) green on push.
- Residual live-host risks documented for the human to validate (not done here).

## Risks
1. **xdg-terminal-exec precedence (HIGHEST).** If the user-config-dir drop-in
   does not win over Ptyxis/system entries, kitty won't be the resolved default
   on GNOME. *Mitigation:* validate on a live GNOME host; documented fallback is
   `update-alternatives` (Ubuntu, `sudo`). Cannot be fully resolved without a
   live desktop apply (out of scope here).
2. **Plasma 6 `TerminalApplication` honoring.** If Plasma 6.x no longer honors
   `kdeglobals [General] TerminalApplication`, the KDE row is inert.
   *Mitigation:* KTD-2 fallback (the same `xdg-terminal-exec` drop-in from U3).
   Validate on a live KDE host.
3. **GNOME Ptyxis-specific entry points are not redirected.** The Quick-Settings
   "New Terminal" and `Ctrl+Alt+T` may stay bound to Ptyxis; only
   portal/xdg-terminal consumers switch to kitty. This is an inherent GNOME
   limitation — R3 covers "default terminal for apps that open one", not every
   Ptyxis hard-binding. Documented scope boundary.
4. **Ubuntu `kitty` archive version lag.** Acceptable; documented.
5. **Managed files deploy in containers (harmless).** Optionally add to the
   container-skip `.chezmoiignore` block for strictness; left optional
   (fcitx5-config-in-container precedent tolerates it).

## Supervisor coordination
None needed — the task is well-specified and the design is data-driven with
clear fallbacks. The one item that genuinely cannot be resolved at planning
time (whether the live targets honor the chosen mechanisms) is a
validation-time question for the implementer/human, captured in Risks, not a
planning blocker.
