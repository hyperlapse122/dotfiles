---
title: KDE Always Dark Theme - Plan
type: feat
date: 2026-09-03
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# KDE Always Dark Theme - Plan

## Goal Capsule

- **Objective:** On every KDE host this repository configures, the desktop is dark at every hour of the day. A user who logs in at noon sees the same dark desktop they see at midnight.
- **Means:** Stop Plasma's day/night switcher from rewriting the color data, pin the icon theme as manifest data, and apply the Breeze Dark color scheme once from a guarded live-session script (KTD1, KTD2, KTD4, KTD5).
- **Authority:** `.chezmoidata/kde.yaml` owns every `kwriteconfig6`-applied Plasma setting. Its row-shape rule — a setting that needs a precondition stays its own script — decides what may be data and what may not. `AGENTS.md` outranks this plan on repository conventions.
- **Execution profile:** One manifest edit, one new KDE script with its capability probe, and the CI skip-declaration audit those add to.
- **Stop conditions:** The earlier stop condition already fired and is resolved: the painted colors cannot be expressed as manifest rows, so the change grew a script. Stop again only if the color scheme cannot be applied without a live Plasma session at all, which would mean this repository cannot own the setting.
- **Tail ownership:** The caller owns commit, push, and PR.

---

## Product Contract

### Summary

Replace automatic day/night theme switching with a hard dark pin. `.chezmoidata/kde.yaml` turns the switcher off, points both of its theme slots at Breeze Dark, and pins the dark icon theme. A new `50-linux-kde` script applies the Breeze Dark color scheme once in a live Plasma session, because the painted colors are not expressible as manifest rows.

### Problem Frame

The desktop switches between Breeze Light and Breeze Dark on Plasma's day/night schedule. `.chezmoidata/kde.yaml:66-69` records that as the intended priority-1 behavior. The user now wants dark at all hours, so that decision is reversed.

Turning the switch off is not enough, and neither is pinning a theme name. On the target host (Plasma 6.7.4) `~/.config/kdeglobals` carries no `[General] ColorScheme` key at all. It carries the **expanded** `[Colors:Button]`, `[Colors:View]`, `[Colors:Window]`, `[Colors:Header]`, `[Colors:Selection]`, `[Colors:Tooltip]`, `[Colors:Complementary]`, `[ColorEffects:Disabled]`, and `[ColorEffects:Inactive]` groups, whose values match `/usr/share/color-schemes/BreezeDark.colors` byte for byte. Those groups are what Plasma paints from, and the switcher is what rewrites them at each transition. `kdeglobals [KDE] LookAndFeelPackage` only records which package was last applied; Plasma does not repaint from it at login.

So disabling the switcher freezes the desktop on whatever colors it last wrote — which is Breeze Light for any apply that lands in daylight. Something must write the dark colors once.

### Key Decisions

- **Dark means Breeze Dark, the package already pinned by `LookAndFeelPackage`.** No third-party or distro dark theme is introduced. Governs R1.
- **A permanent pin is the intended contract, not a default the user can override in System Settings.** Once the switcher is off and the dark colors are applied, a later Global Theme change in the KCM is not reverted by this repository, but the switcher will never restore light either. Governs R3, R4.

### Requirements

**Theme behavior**

- R1. The desktop uses the Breeze Dark color scheme and the `breeze-dark` icon theme at every hour of the day.
- R2. Plasma's automatic day/night Global Theme switching is off, so nothing rewrites the color groups on a schedule.
- R3. The dark color scheme is applied on a host whose colors are not already dark, so the outcome does not depend on the hour the apply happens to run.
- R4. Re-enabling the automatic switch cannot produce a light desktop.

**Repository shape**

- R5. Values are data in `.chezmoidata/kde.yaml`; the live-session work is its own script under `.chezmoiscripts/50-linux-kde/`, matching the existing split.
- R6. The new script declares every early exit through `.chezmoitemplates/skip.sh.tmpl` with a registered capability probe, and `.ci/check-skip-declarations.sh` passes.
- R7. The kde.yaml rationale block states the always-dark behavior, why the color scheme is not a manifest row, and when each part applies.

### Scope Boundaries

- GNOME theming (`.chezmoidata/gnome.yaml`) is untouched.
- The SDDM greeter and Plymouth are untouched. `system/linux/etc/sddm.conf.d/90-breeze.conf` keeps the stock Breeze greeter.
- Per-application themes (Ghostty, VSCodium, browsers) are untouched.
- Cursor theme, splash screen, window decoration, widget style, and wallpaper are untouched — the Breeze and Breeze Dark packages carry identical values for all five.
- Accent color is untouched.

### Sources

- `.chezmoidata/kde.yaml:59-70` (rationale block) and `:150-154` (Global Theme rows) — what this plan edits.
- `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` — the manifest runner. Its group-segment allowlist is `^[A-Za-z0-9_.-]+$`, which rejects the colon in `Colors:Window`; rows are colon-delimited, so the colon could not be admitted without changing the row format.
- `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-wallpaper-breeze.sh.tmpl` — the pattern for the new script: `kde-guard` for host identity, then live-session runtime guards, then a `plasma-apply-*` call.
- `/usr/share/plasma/look-and-feel/org.kde.breezedark.desktop/contents/defaults` — diffed against the light package, only `[kdeglobals][General] ColorScheme` and `[kdeglobals][Icons] Theme` differ.
- Observed host state: `~/.config/kdeglobals` holds expanded `[Colors:*]`/`[ColorEffects:*]` groups and no `[General] ColorScheme`; `~/.config/kdedefaults/kdeglobals` holds `ColorScheme=BreezeDark` and `Icons/Theme=breeze-dark`; `~/.config/kdeglobals` has no `[Icons]` group.
- `AGENTS.md` "Single source of truth", "Apply lifecycle and script tree", "Verification (never deploy live `$HOME`)".

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Turn `AutomaticLookAndFeel` off.** The switcher is what rewrites the expanded color groups on a schedule; with it on, any pin is overwritten at the next transition. Satisfies R2.
- KTD2. **Pin `Icons/Theme` as a manifest row.** The icon theme is a plain name key, and `~/.config/kdeglobals` (which has no `[Icons]` group today) outranks the `~/.config/kdedefaults/kdeglobals` layer that currently supplies it. Satisfies the icon half of R1.
- KTD3. **Do not add a `[General] ColorScheme` manifest row.** On this host that key is absent while the desktop is dark, so it is a label the Colors KCM reads, not the source Plasma paints from. A row would write a name that could disagree with the color groups beside it — worse than writing nothing. Rejected alternative: pin the label and rely on it to repaint.
- KTD4. **Apply the colors with a new guarded script rather than manifest rows.** The painted values live in `[Colors:*]` and `[ColorEffects:*]` groups whose names carry a colon, which the runner's group allowlist rejects and the colon-delimited row format could not carry. Applying them needs a live Plasma session, which is a precondition — and the kde.yaml rule sends a setting with a precondition to its own script. Satisfies R3.
- KTD5. **Use `plasma-apply-colorscheme BreezeDark`, not `plasma-apply-lookandfeel`.** The look-and-feel tool also applies wallpaper, splash, and cursor, which would fight `config-kde-wallpaper-breeze`'s deliberate one-shot wallpaper stamp. `plasma-apply-colorscheme` refuses to reselect an already-selected scheme, so it is idempotent by itself. It also drives kded's GTK sync, which a raw `kwriteconfig6` write does not — that is what keeps GTK applications dark alongside Plasma ones.
- KTD6. **Point `DefaultLightLookAndFeel` at `org.kde.breezedark.desktop` instead of deleting the row.** The runner writes keys and cannot delete them, so a deleted row would leave a stale light value in the deployed `kdeglobals`. Two dark slots mean a re-enabled switcher cannot paint light. Satisfies R4.
- KTD7. **Rejected alternative: leave the switcher on with both slots dark.** That would repaint dark at every transition and needs no new script. It is rejected because the dark desktop would then depend on the switcher continuing to run, on its schedule resolving, and on Plasma keeping those keys — and it does nothing on Plasma versions that ignore them. Switch-off plus a one-time apply holds without any of that.

### Assumptions

- A1. "Always dark" means the Breeze Dark package the repo already pins, not a new theme.
- A2. Only KDE is in scope. The user named KDE; GNOME has its own manifest.
- A3. The manifest rows take effect on their own next-use trigger — for the Global Theme block, after re-login. The color scheme applies as soon as the new script runs in a live session, so no re-login is needed for the colors.

### Implementation Constraints

- Every manifest field must pass the runner's render-time validation. `Icons` passes the field allowlist and `breeze-dark` passes the value allowlist; a violation aborts the apply naming the row.
- The rendered `SETTINGS` array is the manifest runner's `run_onchange_` trigger, so editing rows re-triggers it without a new fingerprint entry. The new script needs its own fingerprint block over its capability probes, exactly as `config-kde-wallpaper-breeze` does.
- The new script sorts after `config-kde-settings` and before `config-kde-touchpad`, so the switcher is already off when the colors are applied. Keep that ordering when naming the file.
- `.chezmoiignore` already excludes `.chezmoiscripts/50-linux-kde/*.sh` for containers, so a new file in that directory needs no ignore entry.
- Adding a `command-present` capability needs only a sorted row in the registry; `.install-prerequisites.sh` derives the command by stripping `-present` and needs no edit.

### Risks

- A host with no live Plasma session at apply time gets the manifest rows but not the colors. That is a declared `transient-blocking` skip: the capability token flips when a session appears and the script re-runs. Until then the desktop keeps its last-applied colors.
- The Definition of Done's dark-desktop check cannot run in CI. It is a manual host check, marked as such.
- `~/.config/kdeglobals [General] ColorSchemeHash` currently matches the dark scheme, so the plan writes nothing that desyncs it; `plasma-apply-colorscheme` maintains it.

---

## Implementation Units

### U1. Pin the dark theme in the KDE settings manifest

- **Goal:** `.chezmoidata/kde.yaml` stops the switcher and states the always-dark intent.
- **Requirements:** R1 (icon half), R2, R4, R7. Applies KTD1, KTD2, KTD3, KTD6.
- **Files:** `.chezmoidata/kde.yaml`
- **Approach:**
  - Edit the Global Theme rows: set `AutomaticLookAndFeel` to `false`, and set `DefaultLightLookAndFeel` to `org.kde.breezedark.desktop`. Leave `LookAndFeelPackage` and `DefaultDarkLookAndFeel` unchanged.
  - Add one row in the same block: `{ file: kdeglobals, group: Icons, key: Theme, type: string, value: breeze-dark }`.
  - Add no `ColorScheme` row, per KTD3.
  - Update the group comment above the rows so it no longer says "automatic day/night".
  - Rewrite the `kdeglobals [KDE] — Global Theme` rationale block (`.chezmoidata/kde.yaml:59-70`), keeping its existing shape. It must state: the desktop is pinned dark at all hours; the switcher is off because it rewrites the expanded color groups on a schedule; both `Default*LookAndFeel` slots are dark so a re-enabled switcher cannot paint light; the icon theme is pinned here because it is a plain name key; the color scheme is deliberately **not** a row here, because the painted values live in `[Colors:*]` groups the row format cannot carry, and `config-kde-theme-dark` owns them. Drop the Plasma < 6.5 fallback paragraph, which described the switching behavior being removed.
- **Test Scenarios:**
  - Rendering `run_onchange_after_config-kde-settings.sh.tmpl` succeeds; `Icons` and `breeze-dark` clear the field and value allowlists, so no `fail` fires.
  - The rendered `SETTINGS` array contains `kdeglobals:KDE:LookAndFeelPackage:string:org.kde.breezedark.desktop`, `kdeglobals:KDE:DefaultLightLookAndFeel:string:org.kde.breezedark.desktop`, `kdeglobals:KDE:DefaultDarkLookAndFeel:string:org.kde.breezedark.desktop`, `kdeglobals:KDE:AutomaticLookAndFeel:bool:false`, and `kdeglobals:Icons:Theme:string:breeze-dark`.
  - The rendered array contains no `ColorScheme` entry.
  - No other row changes, and the other eight `50-linux-kde` scripts render byte-identically — none of them reads `kde.settings`.

### U2. Apply the Breeze Dark color scheme from a guarded script

- **Goal:** A host with a live Plasma session ends up with the dark color groups written, whatever the hour.
- **Requirements:** R1 (color half), R3, R5, R6. Applies KTD4, KTD5.
- **Dependencies:** U1 — the switcher must be off, or the applied colors are overwritten at the next transition.
- **Files:**
  - `.chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-theme-dark.sh.tmpl` (new)
  - `.chezmoidata/.capability-registry.tsv`
- **Approach:**
  - Add one sorted registry row: `plasma-apply-colorscheme-present`, kind `command-present`, side effect `none`, platform `linux`, tokens `available`/`unavailable`. It sorts directly before `plasma-apply-wallpaperimage-present`. No hook change — `command-present` strips the `-present` suffix to get the command.
  - Model the script on `config-kde-wallpaper-breeze`: a `{{ if eq .chezmoi.os "linux" }}` wrapper, capability lookups through `capabilities.tmpl`, a comment-only fingerprint block over those probes, `set -euo pipefail`, then the `kde-guard.sh.tmpl` include.
  - Guard the live session with four `skip_here` declarations, all `transient-blocking`, each naming its probe: no D-Bus session bus (`session-bus-present`), no display server (`graphical-session-present`), plasmashell not running (`plasmashell-running`), and the tool absent (`plasma-apply-colorscheme-present`).
  - Then run `plasma-apply-colorscheme BreezeDark` and echo what it did. Do not add a stamp file: unlike the wallpaper, this setting is meant to be enforced, and the tool already declines to reselect the current scheme.
  - Name the scheme in the script, not in `kde.yaml` — a single literal beside the tool that consumes it, with no manifest row shape to invent for one value.
- **Test Scenarios:**
  - The template renders under the AGENTS.md scratch recipe with no unknown-probe failure, which proves the new registry key is spelled the same at both ends.
  - The rendered script contains four skip sentinels, one per guard, each carrying its declared probe token.
  - Rendered with capabilities unavailable (the ordinary scratch render, which has no hook record), the script takes a skip branch and never reaches `plasma-apply-colorscheme`.
  - `.ci/check-skip-declarations.sh` passes after U3 lands, with the new script's four owners and its `kde-guard` consumer instance accounted for.
  - Registry order: `.chezmoidata/.capability-registry.tsv` still matches the sorted-rows regex in `capabilities.tmpl`, which fails the render if it does not.

### U3. Re-freeze the skip-declaration audit

- **Goal:** The CI audit knows about the new script's skip sites, so `check-skip-declarations.sh` passes.
- **Requirements:** R6. No new KTD — this is bookkeeping the audit design requires.
- **Dependencies:** U2 — the owners must exist before they can be frozen.
- **Files:**
  - `.ci/skip-declaration-site-matrix.yaml`
  - `.ci/check-skip-declarations.sh`
- **Approach:**
  - Add four owner rows under scope `50-linux-kde`, one per U2 guard, each with `template`, `anchor`/`anchor_line`, normalized `predicate` and its `sha256:` digest, `continuation` and its digest, `render_profile: 'linux-kde-session'`, `form: 'skip_here'`, `direction: 'transient-blocking'`, its `probe`, `fingerprint_placement`, and a single `instances` entry. Copy the field shape from the `config-kde-wallpaper-breeze` rows, which carry the same four guards.
  - Add the new script to the `kde-guard/non-kde-desktop` owner's `instances` list and raise `shared_guard_fanout.kde-guard` from 9 to 10.
  - Update `totals`: `classified_owners` 125 → 129, `rendered_instances` 187 → 192, `phase_local_instances` 120 → 124, `shared_guard_instances` 67 → 68. `hard_error_owners` stays 11.
  - Update `audited_forms.skip_here` 54 → 58, `audited_directions.transient-blocking` 56 → 60, and `audited_scopes.50-linux-kde` 29 → 33.
  - Update the `FROZEN` dict at `.ci/check-skip-declarations.sh:196` to the same four totals.
  - Reconcile `plan_contract` against the new `audited_*` values through the existing `divergence` entries rather than editing `plan_contract`, which records the originating plan's numbers verbatim. Add or extend a divergence entry naming this change as the cause.
  - The checker is authoritative on every number above: run it, and take its reported expectation over the arithmetic here if they disagree.
- **Test Scenarios:**
  - `.ci/check-skip-declarations.sh` exits 0 and reports the new instance count.
  - The checker's digest recomputation passes, which proves each recorded `predicate`/`continuation` digest matches its recorded text.
  - Removing one of the four new owner rows makes the checker fail, confirming the rows are actually load-bearing rather than inert additions.
  - `.ci/test-skip-declaration-gates.sh` and `.ci/test-dotfiles-skips.sh` still pass.

---

## Verification Contract

Render through the `AGENTS.md` scratch recipe — never against the live `$HOME`, and never `chezmoi apply`.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
render() {
  env PATH="$scratch/bin:$PATH" chezmoi --config "$scratch/empty.toml" --source "$PWD" \
    --destination "$scratch/target" execute-template < "$1"
}
```

To produce the before side of the scope gate, render all nine `50-linux-kde` templates from a clean tree into one directory — use a second `git worktree` at `HEAD` rather than the stash, since the stash stack is shared with other checkouts — then render them again from the edited tree and `diff -r` the two directories.

| Gate | Command | Passes when |
|---|---|---|
| Manifest renders | `render .chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-settings.sh.tmpl` | exit 0, no `config-kde-settings:` validation failure |
| Manifest rows correct | grep the rendered `SETTINGS` array | the five theme entries in U1 are present and no `ColorScheme` entry exists |
| New script renders | `render .chezmoiscripts/50-linux-kde/run_onchange_after_config-kde-theme-dark.sh.tmpl` | exit 0, no unknown-probe failure, four skip sentinels present |
| Scope is limited | the before/after `diff -r` above | only the two intended scripts differ |
| Skip audit | `.ci/check-skip-declarations.sh` | exit 0 |
| Skip gates | `.ci/test-skip-declaration-gates.sh` and `.ci/test-dotfiles-skips.sh` | both exit 0 |
| Apply behaviour | `.ci/test-kde-theme-dark-apply.sh <rendered-script>` | exit 0; and it must FAIL against a guard that reads `[General] ColorScheme` instead of a painted value |
| CI wiring | `.ci/test-ci-wiring.sh` | exit 0 (the new gate is invoked by a workflow) |
| Tree is clean | `git diff --check` and `git status` | no whitespace errors; only the five files U1-U3 name are changed |
| CI | `render-dotfiles.yml` and `ci.yml` on the pushed branch | both terminal green |

Known blind spot: rendering proves the rows and the guards, not the painted desktop. The visual result is confirmed only by the manual host check below.

---

## Definition of Done

- R1 through R7 are true.
- U1, U2, and U3 are complete and every Verification Contract gate passes.
- Only `.chezmoidata/kde.yaml`, `.chezmoidata/.capability-registry.tsv`, the new script, `.ci/skip-declaration-site-matrix.yaml`, and `.ci/check-skip-declarations.sh` are changed.
- The kde.yaml rationale block describes the always-dark behavior, names `config-kde-theme-dark` as the owner of the color scheme, and no longer describes day/night switching.
- No dead-end edits remain in the diff — no commented-out rows, no abandoned `ColorScheme` row, no leftover stamp logic.
- **Manual host check, not a CI gate.** After the next `chezmoi apply` on a KDE host with a live session, check the artifacts the run actually produces — **not** `kreadconfig6 --group General --key ColorScheme`, which resolves through the KConfig cascade and answers `BreezeDark` from the `kdedefaults` layer whether or not this change did anything:
  - `~/.config/kdeglobals` itself carries the expanded `[Colors:*]` / `[ColorEffects:*]` groups matching `/usr/share/color-schemes/BreezeDark.colors` — spot-check `[Colors:Window] BackgroundNormal` is `32,35,38`.
  - `~/.config/kdeglobals` carries a literal `[Icons]` group with `Theme=breeze-dark` (it had none before; the value previously came from the defaults layer).
  - The apply printed `colour scheme set to BreezeDark`, not `already BreezeDark`, on a host that was not already dark — that line is what proves the script acted rather than skipped.
  - After re-login, the desktop and its GTK applications render dark.

  Record the result; this is the only evidence that R1 holds end to end.

---

## Operational Notes

The color scheme applies as soon as `config-kde-theme-dark` runs in a live session. The icon theme and the switcher keys are manifest rows and take effect at the next login.

A host that applies with no Plasma session running gets the rows but not the colors, and `dotfiles-skips` will list the deferred script. It re-runs on its own once a session exists — the capability token flips and changes the script's rendered content.
