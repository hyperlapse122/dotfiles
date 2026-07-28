---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
title: Kitty Window Chrome and Font Coupling - Plan
type: feat
date: 2026-07-28
topic: kitty-chrome-font-coupling
---

# Kitty Window Chrome and Font Coupling - Plan

## Goal Capsule

- **Objective:** restore kitty's window chrome on Linux and couple kitty's font family to `.chezmoidata/fonts.yaml`, keeping kitty's current 12pt size as a kitty-specific value.
- **Product authority:** the ce-brainstorm dialogue recorded in the Product Contract below (three user-directed decisions: restore titlebar, couple font to fonts.yaml, keep a kitty-specific size).
- **Execution profile:** config/data-only change across 4 files (`fonts.yaml`, `kitty.conf` removed, `kitty.conf.tmpl` added, `AGENTS.md`); no runtime scripts; verification is scratch render + archive + CI, never a live `chezmoi apply`.
- **Stop conditions:** any contradiction with a `session-settled:` KTD; any need to gate the config per desktop or per OS; GNOME live-host validation is a documented residual for the human, not a pipeline blocker.
- **Tail ownership:** commit/push/PR and CI watch belong to the shipping tail, not to the implementation units.

## Product Contract

### Summary

Restore kitty's window chrome on Linux — a KWin titlebar on KDE, kitty's own client-side titlebar on GNOME, from one shared config — and source kitty's font family from `fonts.yaml` while keeping a kitty-specific 12pt size.

### Problem Frame

kitty ships from this repo as the default Linux terminal (`docs/plans/add-kitty-default-terminal-linux.md`). Its managed config, `dot_config/kitty/kitty.conf`, sets `hide_window_decorations yes` (line 9), so on Linux the window has no titlebar, borders, or window buttons — confirmed by a user screenshot on KDE Wayland (kitty 0.47.1). The same config sets no `font_family`, so kitty renders in its fallback monospace instead of the repo's managed mono family, and its header records a deliberate choice not to couple to `fonts.yaml` (KTD-5 of the prior plan).

### Key Decisions

- **Chrome restored via one shared config, no desktop branching.** `hide_window_decorations no` yields a native titlebar on KDE (KWin server-side decorations) and kitty's own client-side titlebar on GNOME; a single managed file covers both desktops.
- **Font coupled to `fonts.yaml`, reversing KTD-5.** The managed config renders its font family from `families.mono` (`JetBrainsMono Nerd Font`) instead of carrying no family, and the `fonts.yaml` header/consumer documentation gains kitty as a consumer. Chosen over literal family names in kitty.conf: the repo's single-source-of-truth convention for fonts.
- **Kitty keeps its own size.** `fonts.yaml` gains a kitty-specific size (12) rather than reusing the shared `sizes.mono` (10), preserving the current on-screen feel.

### Requirements

**Window chrome**

- R1. kitty windows on Linux show window chrome — a titlebar with window controls — on KDE hosts.
- R2. kitty windows on Linux show window chrome — kitty's own client-side titlebar — on GNOME hosts.
- R3. Chrome restoration uses one shared managed config with no per-desktop branching.

**Font**

- R4. kitty's font family is the managed mono family from `.chezmoidata/fonts.yaml` (`families.mono`), rendered from the data rather than written as a literal in the kitty config.
- R5. kitty's font size comes from a kitty-specific entry in `fonts.yaml` at 12pt, not the shared `sizes.mono`.

**Repo conventions**

- R6. The `fonts.yaml` header comment (which enumerates its consumers) is updated to include kitty.
- R7. Verification follows AGENTS.md: scratch-destination renders and archive checks, never a live `chezmoi apply`.

### Acceptance Examples

- AE1. **Covers R1, R3.** Given a KDE Wayland host, when kitty opens, then the window shows a KWin titlebar with minimize/maximize/close buttons.
- AE2. **Covers R2, R3.** Given a GNOME Wayland host running a current kitty, when kitty opens, then the window shows kitty's own titlebar.
- AE3. **Covers R4.** Given `families.mono` is edited in `fonts.yaml`, when the kitty config re-renders, then kitty uses the new family with no edit to the kitty config itself.

### Scope Boundaries

- macOS: this repo does not install kitty there (prior plan is Linux-only); the config file deploys harmlessly with no consumer. No macOS behavior is part of this work.
- No kitty theme, palette, or other `kitty.conf` tunables beyond chrome and font.
- No `linux_display_server x11` / XWayland forcing to obtain decorations.
- No changes to the prior plan's package gating or default-terminal wiring.

### Dependencies / Assumptions

- KDE Wayland (KWin) provides server-side decorations to kitty — verified on the current host (KDE Wayland, kitty 0.47.1).
- On GNOME, kitty draws its own client-side titlebar; fully functional buttons that follow system dark/light mode are a recent-kitty behavior. The Ubuntu archive's kitty version may lag upstream — validate on a live GNOME host after apply.

### Sources / Research

- `dot_config/kitty/kitty.conf` — current managed config; `hide_window_decorations yes` at line 9, no `font_family`.
- `.chezmoidata/fonts.yaml` — `families.mono`, `monoFallbacks`, `sizes`; header documents the consumer list this plan extends.
- `docs/plans/add-kitty-default-terminal-linux.md` — KTD-5 records the deliberate `hide_window_decorations yes` + no-fonts.yaml-coupling decision this plan reverses.
- [kitty changelog](https://sw.kovidgoyal.net/kitty/changelog/) — kitty's GNOME window decorations are client-side, now fully functional with buttons and system dark/light following; see also the `wayland_titlebar_color` option in the [kitty.conf docs](https://sw.kovidgoyal.net/kitty/conf/).

## Planning Contract

Product Contract preservation: **unchanged**.

### Key Technical Decisions

- **KTD-1 — explicit `hide_window_decorations no` in one shared config.** (session-settled: user-directed — chosen over keeping the borderless chrome-free window: the user reported the missing chrome as a defect and wants titlebar drag/buttons back.) `no` is kitty's default, but the line stays explicit to document the reversal of the prior deliberate `yes`. KWin draws the titlebar on KDE; kitty draws its own client-side titlebar on GNOME; no desktop branching (implements the Product Contract's shared-config decision, session-settled: user-directed — chosen over per-desktop gating: kitty's CSD covers GNOME with the same setting).
- **KTD-2 — `kitty.conf` becomes `kitty.conf.tmpl` reading `.fonts.families.mono`.** (session-settled: user-directed — chosen over literal family names in kitty.conf: the repo's single-source-of-truth convention for fonts.) Mirrors the VSCodium (`settings.json.tmpl`) and fcitx5 (`classicui.conf.tmpl`) pattern, including their "A .tmpl for ONE reason" header convention; the old header's "does NOT couple to fonts.yaml" note is replaced.
- **KTD-3 — new `fonts.sizes.terminal: 12` key.** (session-settled: user-directed — chosen over sharing `sizes.mono` (10pt): preserves kitty's current 12pt on-screen feel.) kitty renders `font_size` from this key.
- **KTD-4 — render only `families.mono`, not `monoFallbacks`.** kitty takes one family per style and falls back through fontconfig for missing glyphs; Korean coverage comes from the installed D2Coding faces. `monoFallbacks` is VSCodium's CSS-stack concept and has no kitty analog.
- **KTD-5 — no `wayland_titlebar_color`.** kitty's default (`system`) already follows system colors for the GNOME client-side titlebar.
- **KTD-6 — no `.chezmoiignore` or macOS gating.** The config deploys on every target harmlessly, matching the prior plan's container precedent; kitty itself installs only on Linux desktops.

### Assumptions

- GNOME hosts run a kitty new enough for the fully functional client-side titlebar (buttons, system dark/light following). The Ubuntu archive kitty version may lag — a live GNOME host check is the human's residual validation item.
- The managed font faces (`JetBrainsMono Nerd Font`, D2Coding fallbacks) are installed on every desktop host via the fonts.yaml archives and font scripts; not re-verified per host in this change.

## Implementation Units

### U1. Add the kitty size key and consumer docs to fonts.yaml

- **Goal:** add `sizes.terminal: 12` and name kitty in the `fonts.yaml` header's consumer enumeration.
- **Requirements:** R5, R6
- **Dependencies:** none
- **Files:** `.chezmoidata/fonts.yaml`
- **Approach:** add `terminal: 12` under `sizes:` with a comment stating it is kitty's terminal size and intentionally separate from `sizes.mono` (10pt). Update the header comment that enumerates consumers ("the KDE and GNOME font scripts, the fcitx5 classicui config, and the VSCodium settings") to include kitty, and update the header's trailing count sentence from "all four follow" to "all five follow" (the historical "it used to be a four-file edit" clause stays as past tense).
- **Patterns to follow:** the existing `sizes:` map entries and header comment style in `fonts.yaml`.
- **Test scenarios:** `Test expectation: none` — data/comment edit; its effect is proven by U2's render check.

### U2. Replace kitty.conf with a fonts-coupled template and restore chrome

- **Goal:** swap the self-contained `kitty.conf` for `kitty.conf.tmpl` that restores window chrome and renders the managed mono family and terminal size from `fonts.yaml`.
- **Requirements:** R1, R2, R3, R4, R5; KTD-1 through KTD-6
- **Dependencies:** U1
- **Files:** `dot_config/kitty/kitty.conf` (removed), `dot_config/kitty/kitty.conf.tmpl` (created)
- **Approach:** rewrite the header comment to state the fonts.yaml coupling, replacing the old "does NOT couple to fonts.yaml" note. Set `hide_window_decorations no` with a comment noting KWin SSD on KDE and kitty CSD on GNOME. Render `font_family {{ .fonts.families.mono }}` and `font_size {{ .fonts.sizes.terminal }}`. Every other existing directive stays literal and unchanged.
- **Patterns to follow:** `dot_config/VSCodium/User/settings.json.tmpl` (header + `.fonts.families.mono` access), `dot_config/fcitx5/conf/classicui.conf.tmpl` (family + size access).
- **Test scenarios:**
  1. Covers AE3. Render `kitty.conf.tmpl` through the scratch chezmoi harness → output contains `font_family JetBrainsMono Nerd Font`, `font_size 12`, and `hide_window_decorations no`.
  2. The rendered template contains no unresolved `{{` markers and keeps all previously literal directives (cursor, scrollback, clipboard, bell, window size).
  3. `chezmoi archive` target tree contains `.config/kitty/kitty.conf` with the rendered values.
- **Verification:** the render and archive checks in the Verification Contract pass, and the rendered diff against the old config touches only the header, the decorations line, and the two font lines.

### U3. Update the AGENTS.md fonts.yaml consumer row

- **Goal:** the single-source-of-truth table in `AGENTS.md` names kitty as a fonts.yaml consumer.
- **Requirements:** R6
- **Dependencies:** U2 (the row must describe the shipped state)
- **Files:** `AGENTS.md`
- **Approach:** extend the `fonts.yaml` row's consumer description to include kitty alongside KDE/GNOME/fcitx/VSCodium. `CLAUDE.md` stays the bare `@AGENTS.md` include — no change needed.
- **Patterns to follow:** the existing table row phrasing in `AGENTS.md`.
- **Test scenarios:** `Test expectation: none` — documentation edit verified by diff review.

## Verification Contract

Per AGENTS.md: per-user scratch directory, stub `op`, empty config, throwaway destination, `--source "$PWD"`. Never a live `chezmoi apply`.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
# Render the new kitty template through the stub:
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < dot_config/kitty/kitty.conf.tmpl
# Target-tree check (archive omits scripts — no scripts change here, so no blind spot):
chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" archive --exclude=encrypted,externals,scripts
```

- The rendered template shows `font_family JetBrainsMono Nerd Font`, `font_size 12`, `hide_window_decorations no`, and no unresolved template markers.
- The archive target tree deploys `.config/kitty/kitty.conf` with those values.
- `git diff --check` and `git status` confirm the diff is limited to the 4 files: `.chezmoidata/fonts.yaml`, `dot_config/kitty/kitty.conf` (deleted), `dot_config/kitty/kitty.conf.tmpl` (added), `AGENTS.md`.
- **Onchange disclosure (per AGENTS.md):** the fonts.yaml edit changes the fingerprint embedded in `config-kde-fonts` and `config-gnome-fonts`, so both run_onchange font scripts idempotently re-run once on the next live apply. No other side effects.
- CI on push: `render-dotfiles.yml` and `ci.yml`, watched to terminal success.
- **Behavior-change signal:** config/rendering-only; this repo has no unit-test layer for chezmoi data. The bar is render + archive + CI, matching the prior kitty plan. Tests added: none.
- **NO** live `chezmoi apply`, **NO** real kitty launch as "verification".

## Definition of Done

- `.chezmoidata/fonts.yaml` carries `sizes.terminal: 12` and the updated consumer enumeration.
- `dot_config/kitty/kitty.conf` is replaced by `kitty.conf.tmpl` rendering family and size from `fonts.yaml` with `hide_window_decorations no`.
- `AGENTS.md` names kitty as a fonts.yaml consumer.
- Render + archive checks pass; the rendered config differs from the old one only in the header, decorations, and font lines.
- `git diff --check` clean; diff limited to the 4 files; no leftover experimental files.
- CI (`render-dotfiles.yml` + `ci.yml`) green on push.
- The GNOME live-host titlebar validation is documented as a residual human check, not performed here.
