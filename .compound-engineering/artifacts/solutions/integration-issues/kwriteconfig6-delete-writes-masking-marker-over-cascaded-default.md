---
title: "kwriteconfig6 --delete writes a Key[$d] marker that masks kdedefaults when /etc/xdg sets the key"
date: "2026-10-09"
category: integration-issues
module: "KDE Plasma automatic light/dark theme (Home Manager activation, home/h82/desktop/kde/theme.nix)"
problem_type: integration_issue
component: activation
symptoms:
  - "After the kdeTheme activation, ~/.config/kdeglobals holds ColorScheme[$d] and Theme[$d] lines instead of no entry"
  - "With AutomaticLookAndFeel on, a night login would read the BreezeLight fallback while LookAndFeelPackage names Breeze Dark"
  - "A check that tests absence with key= passes, because Key[$d] does not start with key="
root_cause: wrong_api
resolution_type: code_fix
severity: medium
related_components:
  - testing_framework
  - home-manager
tags: ["kde-plasma", "kdeglobals", "kwriteconfig6", "kreadconfig6", "kconfig-cascade", "kdedefaults", "xdg-config-dirs", "automatic-look-and-feel", "deletion-marker"]
---

# kwriteconfig6 --delete writes a Key[$d] marker that masks kdedefaults when /etc/xdg sets the key

## Problem

The automatic light/dark change (branch `feat/auto-appearance-mode`) turns on Plasma's `[KDE] AutomaticLookAndFeel`. It also has the `kdeTheme` Home Manager activation remove three user entries: `[General] ColorScheme`, `[General] ColorSchemeHash`, and `[Icons] Theme`. The first version removed them with `kwriteconfig6 --delete`. Because `/etc/xdg/kdeglobals` (`modules/nixos/desktop/desktop.nix`) sets `ColorScheme` and `Icons/Theme`, KConfig did not remove those keys. It wrote `[$d]` deletion markers, and the markers hide every lower config layer, including the `~/.config/kdedefaults` layer where Plasma puts the scheduled theme.

## Symptoms

- After the activation, the user `kdeglobals` held `ColorScheme[$d]` and `Theme[$d]` where a removed key was expected.
- The consequence, traced through the Plasma source (no session was run): at a night login Plasma picks Breeze Dark but reads the masked `ColorScheme` as its `BreezeLight` fallback and applies light colors. The in-session switcher then skips its own apply because `LookAndFeelPackage` already names Breeze Dark.
- The first `tests/kde-theme.nix` passed anyway, because its absence check matched only `key=`.

## Why the pins had to go

With `AutomaticLookAndFeel=true`, `startplasma` decides the day or night package at login (pinned `plasma-workspace` 6.7.5, `startkde/startplasma.cpp`):

- It prepends `~/.config/kdedefaults` to `XDG_CONFIG_DIRS` (lines 406-413).
- It writes the package's scheme and icon theme there through `KLookAndFeelManager` in `Mode::Defaults` (line 429). That mode writes only the `kdedefaults` file; it reverts the user's own entry only in `Mode::Apply` (`libklookandfeel/klookandfeelmanager.cpp:388-391`).
- It reads the effective `ColorScheme` with a `BreezeLight` fallback (line 438) and re-applies colors only when `[General] ColorSchemeHash` no longer matches the scheme file (line 447).

So a user-file `ColorScheme` or `Icons/Theme` outranks the scheduled theme. The `lookandfeelautoswitcher` kded module does not repair this, because it returns early when `LookAndFeelPackage` already equals its target (`kcms/lookandfeel/kded/lookandfeelautoswitcher.cpp:124-126`). The activation therefore has to remove those user entries, and deleting `ColorSchemeHash` makes the next login re-apply the scheduled scheme's colors.

## What Didn't Work

- **Plain `kwriteconfig6 --delete` with the session's config dirs.** `kwriteconfig6` opens the file with `KConfig::NoGlobals` and calls `cfgGroup.deleteEntry(key, flags)` (pinned kconfig 6.30.0, `src/kreadconfig/kwriteconfig.cpp:62` and `:84`). When the file is written, a deleted key with no default is erased (`src/core/kconfigini.cpp:436`). One that has a default from any lower layer is written as an explicitly deleted entry, `Key[$d]` (`:439`). `/etc/xdg/kdeglobals` always sets the scheme and icon theme, so the delete produced a marker. A marker hides every lower layer, including `kdedefaults`.
- **Checking absence with `key=`.** The check's `ini_has` helper matched lines starting with `key=`, so `ColorScheme[$d]` passed as "absent". It also ran the activation with only `/etc/xdg` in `XDG_CONFIG_DIRS` (the branch's first version, before the review fix), so nothing modelled the `kdedefaults` layer the marker was hiding. A cross-model adversarial code review (Codex) found both problems before the branch shipped.

## Solution

Run the three deletes with no system config dirs, so KConfig sees no default and erases the key, including any marker already in the file (`home/h82/desktop/kde/theme.nix:25-27`):

```nix
XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group General --key ColorScheme --delete
XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group General --key ColorSchemeHash --delete
XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group Icons --key Theme --delete
```

The writes that turn the switch on still run with the session's dirs, because dropping a user entry that equals the `/etc/xdg` value is harmless there.

`tests/kde-theme.nix` now models a session:

- It seeds `~/.config/kdedefaults/kdeglobals` with `ColorScheme=BreezeDark` and `Theme=breeze-dark` and runs the activation with `XDG_CONFIG_DIRS` set to that dir followed by the built `/etc/xdg` (lines 172-174, 198-203).
- `expectDeleted` uses `ini_mentions`, which also matches `key[`, so a marker fails the check (line 183).
- `expectResolved` asks the packaged `kreadconfig6` for the scheme and icon theme under the same environment and expects the `kdedefaults` values (lines 188-190).

## Why This Works

KConfig decides between erasing and marking only when it writes the file, and it decides by whether any lower layer supplies a default. With `XDG_CONFIG_DIRS=/var/empty` no lower layer exists for that one `kwriteconfig6` process, so the entry is erased. The session then resolves the key normally: no user entry, then `kdedefaults`, then `/etc/xdg`.

Resolving through `kreadconfig6` with the session's dirs tests what Plasma itself will read. That catches a marker, a surviving user pin, or a lost `kdedefaults` layer alike, rather than a guess at the file's syntax.

## Prevention

- Before deleting a KConfig key that a lower layer (`/etc/xdg`, `kdedefaults`, a distribution default) also sets, decide which you want: `--delete` with the cascade visible writes a masking `[$d]` marker, and `--delete` with no cascade restores inheritance. `KLookAndFeelManager` clears a user entry with `revertToDefault` (`klookandfeelmanager.cpp:389`), which `kwriteconfig6` does not expose.
- Assert config state through `kreadconfig6` under the real `XDG_CONFIG_DIRS`, not by grepping `key=` in the user file. When a grep is unavoidable, match `key[` as well. This is the same principle as the cascade-aware `ini_effective` lookup in `.compound-engineering/artifacts/solutions/integration-issues/plasma-apply-colorscheme-no-op-under-xdg-kdeglobals-cascade.md`.
- Include every layer the session has. A test without `kdedefaults` cannot see a defect that only hides `kdedefaults`.
- Do not exercise KConfig tools on macOS with a fake `HOME`. As observed in this session, Qt on macOS resolves the config location to `~/Library/Preferences` regardless of `HOME` and `XDG_CONFIG_HOME`: a local run of `kwriteconfig6 --file kdeglobals` wrote the real `~/Library/Preferences/kdeglobals`, and the file had to be removed by hand. Pass an absolute `--file` path on a Mac, and expect cascade behavior to be testable only on Linux.

## Related Issues

- `.compound-engineering/artifacts/solutions/integration-issues/plasma-apply-colorscheme-no-op-under-xdg-kdeglobals-cascade.md`: the opposite trap in the same cascade, where an apply tool reads the cascaded value as already set and writes nothing.
- `.compound-engineering/artifacts/solutions/best-practices/converged-fixture-state-defeats-nix-check-mutation-testing.md`: seed fixtures with wrong values so a skipped write cannot pass.
- `.compound-engineering/artifacts/solutions/best-practices/home-manager-activation-does-not-run-on-every-rebuild.md`: the activation runs only when the generation changes.
