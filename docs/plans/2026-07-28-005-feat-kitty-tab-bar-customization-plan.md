---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
title: Kitty Tab Bar Customization - Plan
type: feat
date: 2026-07-28
topic: kitty-tab-bar-customization
---

# Kitty Tab Bar Customization - Plan

## Goal Capsule

- **Objective:** make kitty's tab bar explicit and customized in the managed config — position, style, and title template — plus tab-related key mappings (switch on page-up/down, cwd-inheriting new tab with the home-directory variant preserved).
- **Product authority:** direct user request (LFG pipeline): "customize kitty's behavior — tab appearance and position first, other tab/window behavior where sensible." Aesthetic defaults chosen under pipeline scaffolding are recorded as Assumptions.
- **Execution profile:** single-file config change (`dot_config/kitty/kitty.conf.tmpl`); no scripts, no data files; verification is scratch render + archive + CI, never a live `chezmoi apply`.
- **Stop conditions:** any contradiction with plan 004's `session-settled:` KTDs (chrome `no`, fonts.yaml coupling — those lines are not touched); any need for per-desktop branching.
- **Tail ownership:** commit/push/PR and CI watch belong to the shipping tail, not to the implementation units.

## Product Contract

### Summary

The managed kitty config carries no tab settings, so the tab bar rides kitty's upstream defaults (bottom edge, `fade` style, plain title, `ctrl+shift+left/right` switching only). This plan makes the tab surface explicit: the bar moves to the top edge in `powerline` style with an index-prefixed title template, and gains conventional tab key mappings including new-tab-inherits-cwd.

### Problem Frame

kitty is this repo's default Linux terminal with a fully managed `kitty.conf.tmpl` (plan 004 coupled its chrome and font to `fonts.yaml`). Every tab behavior is currently an invisible upstream default: the user cannot see which choices are deliberate, and the tab bar's look/position — the user's stated priority — is unconfigured. kitty renders powerline separators itself and the managed mono face is `JetBrainsMono Nerd Font`, so a `powerline` tab bar is glyph-safe on every managed host.

### Requirements

- R1. The tab bar position is explicit and relocated to the top edge.
- R2. The tab bar style is explicit — `powerline` with a chosen separator shape — and renders correctly with the managed fonts on both KDE and GNOME.
- R3. Tab titles carry the tab index (usable with `goto_tab N`) while preserving kitty's bell/activity symbols.
- R4. Tab switching is available on conventional `ctrl+page_up`/`ctrl+page_down` bindings in addition to kitty's defaults (which already include tab move on `ctrl+shift+,`/`ctrl+shift+.`).
- R5. New tabs opened with `ctrl+shift+t` inherit the current working directory.
- R6. The change is one managed config file; the plan-004 chrome/font lines and the fonts.yaml coupling stay byte-identical.

### Scope Boundaries

- No tab color overrides: the repo manages no kitty palette, so upstream default tab colors stay; a palette is a separate theme decision.
- No `tab_bar.py` custom draw function, no session/`tab_bar_filter` machinery.
- No changes to `fonts.yaml`, chrome/decorations, or any plan-004 deliverable.
- macOS: config deploys harmlessly with no consumer (plan-004 precedent); not part of this work.

### Dependencies / Assumptions

- kitty's shell integration is active for the managed zsh, so `new_tab_with_cwd` can read the current directory — kitty enables shell integration by default; if a host disables it, the binding falls back to home-directory behavior, not an error.
- kitty renders `powerline` tab separators internally; `JetBrainsMono Nerd Font` (installed via fonts.yaml archives) covers any residual glyph needs.

## Planning Contract

### Key Technical Decisions

- **KTD-1 — `tab_bar_edge top`.** Chosen over kitty's upstream default `bottom`: the user asked for the position to change, and top matches browser/editor tab conventions on both desktops. (Pipeline default — see Assumptions.)
- **KTD-2 — `tab_bar_style powerline` + `tab_powerline_style slanted`.** Chosen over `fade` (upstream default), `separator`, and `slant`: a continuous styled bar is the visible "모양" customization requested, and glyph safety is guaranteed by the managed Nerd Font. `slant` was the runner-up but reads busier at 12pt.
- **KTD-3 — `tab_title_template "{index}: {title}"`.** Chosen over the upstream template: the index makes `goto_tab N` discoverable. kitty auto-prepends `{bell_symbol}`/`{activity_symbol}` when absent from the template (documented backward compatibility), so R3's symbol preservation needs no explicit tokens.
- **KTD-4 — explicit `tab_switch_strategy previous`.** Upstream default kept and written explicitly: closing a tab returns to the last-used tab, and the line documents the choice per this file's comment convention.
- **KTD-5 — default tab colors, no palette.** Chosen over hardcoding `active_tab_*`/`inactive_tab_*` colors: with no managed palette, literal colors would clash with host themes; the powerline style alone carries the visual change.
- **KTD-6 — `ctrl+shift+t` remapped to `new_tab_with_cwd`, plus `ctrl+shift+alt+t` for plain `new_tab`.** Chosen over leaving `new_tab` (home directory) on the primary binding: cwd inheritance is the near-universal terminal expectation and degrades gracefully without shell integration. The companion `ctrl+shift+alt+t new_tab` binding keeps the upstream home-directory behavior keyboard-reachable — the remap alone would make `new_tab` unreachable by key.
- **KTD-7 — only genuinely unmapped keys are bound.** `ctrl+page_up`/`ctrl+page_down` switch tabs (unmapped upstream; kitty key names are `page_up`/`page_down`). Tab move stays on the upstream `ctrl+shift+,`/`ctrl+shift+.` (`move_tab_backward`/`move_tab_forward`) — deliberately NOT duplicated onto `ctrl+shift+page_up`/`ctrl+shift+page_down`, which upstream maps to `scroll_page_up`/`scroll_page_down` (kitty_mod+page_*); overriding them would silently remove keyboard page-scrolling. All upstream mappings stay intact, so no muscle memory breaks.

### Assumptions

- **Aesthetic defaults are pipeline-chosen, user-adjustable.** The user asked for tab appearance/position customization without naming values; KTD-1/2/3 pick `top` + `powerline slanted` + indexed titles as the defensible default. Adjusting any of them is a one-line edit in the same section.
- Current kitty on managed hosts supports every directive used (all are long-standing options; `tab_powerline_style` and the template variables predate the Ubuntu archive kitty).

## Implementation Units

### U1. Add the explicit tab bar section to kitty.conf.tmpl

- **Goal:** a `# --- tab bar ---` section makes position, style, title template, and switch strategy explicit.
- **Requirements:** R1, R2, R3, R6; KTD-1 through KTD-5
- **Dependencies:** none
- **Files:** `dot_config/kitty/kitty.conf.tmpl`
- **Approach:** insert one section (placement after the `# --- window ---` section, before `# --- font ---`) containing `tab_bar_edge top`, `tab_bar_style powerline`, `tab_powerline_style slanted`, `tab_title_template "{index}: {title}"`, and `tab_switch_strategy previous`. Follow the file's comment convention: each directive or small group gets a comment stating the reason and the upstream default it reverses or keeps — mirroring how the chrome line documents its reversal. The header comment's ".tmpl for ONE reason" note stays accurate (tab lines are literal, joining "everything else here is kitty's own settings surface").
- **Patterns to follow:** the existing section-comment style in `dot_config/kitty/kitty.conf.tmpl` (e.g. the `# --- window ---` block).
- **Test scenarios:**
  1. Render `kitty.conf.tmpl` through the scratch chezmoi harness → output contains `tab_bar_edge top`, `tab_bar_style powerline`, `tab_powerline_style slanted`, `tab_title_template "{index}: {title}"`, `tab_switch_strategy previous`.
  2. The rendered file has no unresolved `{{` markers, and the chrome/font lines from plan 004 are byte-identical to the pre-change render.
  3. `chezmoi archive` target tree contains `.config/kitty/kitty.conf` with the tab section rendered.

### U2. Add tab key mappings to kitty.conf.tmpl

- **Goal:** conventional tab switch bindings and a cwd-inheriting new tab with the home-directory variant preserved.
- **Requirements:** R4, R5; KTD-6, KTD-7
- **Dependencies:** U1 (same file, same edit section family)
- **Files:** `dot_config/kitty/kitty.conf.tmpl`
- **Approach:** add a `# --- key bindings ---` section after U1's section with `map ctrl+page_up previous_tab`, `map ctrl+page_down next_tab`, `map ctrl+shift+t new_tab_with_cwd`, and `map ctrl+shift+alt+t new_tab`, each with a reason comment. The cwd binding's comment notes the shell-integration dependency and graceful fallback; the `ctrl+shift+alt+t` comment states it preserves the upstream home-directory behavior the remap replaced. A section comment records the deliberate non-bindings: tab move stays on upstream `ctrl+shift+,`/`ctrl+shift+.`, and `ctrl+shift+page_up`/`ctrl+shift+page_down` keep their upstream `scroll_page_up`/`scroll_page_down` actions (KTD-7).
- **Patterns to follow:** kitty's documented key-name syntax (`page_up`/`page_down`) and the file's comment convention.
- **Test scenarios:**
  1. Render through the scratch harness → all four `map` lines present with kitty key-name syntax.
  2. No binding duplicates an upstream default mapping with a different action, except the two deliberate overrides — `ctrl+shift+t` (`new_tab` → `new_tab_with_cwd`) — while `ctrl+page_up`/`ctrl+page_down` are unmapped upstream and `ctrl+shift+page_up`/`ctrl+shift+page_down` (upstream `scroll_page_up`/`scroll_page_down`) are deliberately left untouched.
- **Verification for U1+U2:** the Verification Contract render/archive checks pass; the rendered diff against the pre-change config adds exactly the two new sections and touches nothing else.

## Verification Contract

Per AGENTS.md: per-user scratch directory, stub `op`, empty config, throwaway destination, `--source "$PWD"`. Never a live `chezmoi apply`.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
# Render the kitty template through the stub:
env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < dot_config/kitty/kitty.conf.tmpl
# Target-tree check (archive omits scripts — no scripts change here, so no blind spot):
chezmoi --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" archive --exclude=encrypted,externals,scripts
```

- The rendered template shows the tab bar section (edge/style/powerline style/title template/switch strategy) and the four `map` lines, with no unresolved template markers.
- The chrome (`hide_window_decorations no`) and font (`font_family`/`font_size`) lines are unchanged versus the pre-change render.
- The archive target tree deploys `.config/kitty/kitty.conf` with the new sections.
- `git diff --check` and `git status` confirm the diff is limited to `dot_config/kitty/kitty.conf.tmpl` plus this plan file.
- CI on push: `render-dotfiles.yml` and `ci.yml`, watched to terminal success.
- **Behavior-change signal:** config-only; this repo has no unit-test layer for chezmoi data. The bar is render + archive + CI, matching plan 004. Tests added: none. A live kitty smoke check (tab bar on top, powerline style, `ctrl+shift+t` cwd inheritance) is the human's residual validation after the next real apply — documented, not a pipeline blocker.
- **NO** live `chezmoi apply`, **NO** real kitty launch as "verification".

## Definition of Done

- `dot_config/kitty/kitty.conf.tmpl` carries the explicit `# --- tab bar ---` and `# --- key bindings ---` sections per KTD-1 through KTD-7, in the file's comment style.
- Plan-004 lines (chrome, font family/size, header coupling note) are byte-identical after the change.
- Render + archive checks pass; rendered diff adds only the two new sections.
- `git diff --check` clean; diff limited to `dot_config/kitty/kitty.conf.tmpl` and this plan file.
- CI (`render-dotfiles.yml` + `ci.yml`) green on push.
- Live kitty smoke check documented as a residual human item, not performed here.

## Sources & Research

- `dot_config/kitty/kitty.conf.tmpl` — current managed config; no tab directives; comment convention this plan mirrors.
- `docs/plans/2026-07-28-004-feat-kitty-chrome-font-coupling-plan.md` — session-settled chrome/font state this plan must not disturb; plan style precedent.
- [kitty options definition (upstream source)](https://github.com/kovidgoyal/kitty/blob/master/kitty/options/definition.py) — authoritative defaults and choices for `tab_bar_edge` (default `bottom`), `tab_bar_style`, `tab_powerline_style`, `tab_title_template` (bell/activity auto-prepend), `tab_switch_strategy`, tab colors; retrieved verbatim during planning.
- [kitty.conf docs](https://sw.kovidgoyal.net/kitty/conf/) — key-name syntax and tab bar option documentation.
