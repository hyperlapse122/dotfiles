---
title: Twemoji configured as the emoji font but most apps never draw it
date: "2026-10-06"
category: integration-issues
module: NixOS fonts & fontconfig
problem_type: integration_issue
component: typography
symptoms:
  - "`defaultFonts.emoji` lists Twitter Color Emoji first, yet Chromium, Electron, KDE, and GTK apps show monochrome or Noto emoji"
  - "`fc-match emoji` returns Twitter Color Emoji while plain text falls back to DejaVu Sans for U+1F600"
  - "Ghostty reports U+1F600 found in face Noto Color Emoji"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [twemoji, emoji, fontconfig, ghostty, cbdt, svginot, dejavu, font-cache]
---

# Twemoji configured as the emoji font but most apps never draw it

## Problem

`modules/nixos/desktop/fonts.nix` named Twitter Color Emoji as the first `fonts.fontconfig.defaultFonts.emoji` entry, but apps other than Firefox drew emoji in monochrome or in Noto's design. Three separate mechanisms each kept Twemoji out, and fixing one does not reveal the next: the font format, the scope of the `emoji` alias, and Ghostty's own fallback. A fourth fontconfig behavior limits what the fix can reach (see Why This Works).

## Symptoms

- Emoji in Chromium, Electron, KDE, and GTK apps render as DejaVu Sans's monochrome glyphs or as Noto Color Emoji.
- `fc-match emoji` says Twitter Color Emoji, which makes the configuration look correct.
- `ghostty +show-face --string=😀` reports Noto Color Emoji.

## What Didn't Work

- **Probing with `fc-match "<family>:charset=1f600"`.** fontconfig scores the charset as one weak element, so the result is not the font an app falls back to. Skia, Pango, and Qt take the `fc-match -s <family>` order and use the first font whose charset covers the codepoint. The `charset=` probe happened to agree on the original host and disagreed after the fix.
- **A `<match target="scan">` rule that subtracts the emoji blocks from monochrome fonts' charsets.** NixOS pre-builds the font cache with only upstream `fonts.conf` (nixpkgs `make-fonts-cache.nix` includes `${fontconfig.out}/etc/fonts/fonts.conf` and nothing else), and `00-nixos-cache.conf` lists that `<cachedir>` first. The cached font patterns never pass through user scan rules. With the cachedir line removed, the same rule dropped DejaVu Sans and Unifont Upper from the U+1F600 coverage set, so the rule itself was correct and the cache was the blocker.
- **Appending Twemoji to every pattern with `binding="strong"` (`mode="append_last"`).** That fixed named families such as `Noto Sans`, but a request for an uninstalled family then resolved ASCII digits and space to Twemoji, because Twemoji covers `0`-`9`, `#`, `*`, and space.
- **Trusting an experiment's cached ordering.** An `XDG_CACHE_HOME` reused across experiments, including one run without the prebuilt cachedir, produced a correct-looking `Noto Sans` order that a fresh cache directory did not reproduce. Use a new cache directory per experiment.

## Solution

One fix per mechanism, plus a check that proves them.

1. **Install the CBDT build.** `twemoji-color-font` ships `TwitterColorEmoji-SVGinOT.ttf`, an OpenType-SVG font that, as observed in this session, only Firefox draws in color. nixpkgs `twitter-color-emoji` is a CBDT bitmap font with the same family name, so `defaultFonts.emoji` needs no rename (the package list is in `modules/shared/font-packages.nix`; `emojiFont` in `modules/nixos/desktop/fonts.nix` names the family).
2. **List Twemoji after each primary font in the generic families.** `defaultFonts.emoji` only applies when an app requests the `emoji` family. Plain text in `sans-serif`, `serif`, or `monospace` reaches whatever font covers the codepoint first, and that was DejaVu Sans. Append Twemoji right after the primary font of each list (the `sansSerif`, `serif`, and `monospace` lists in `modules/nixos/desktop/fonts.nix`):

   ```nix
   sansSerif = [ "Pretendard" emojiFont ];
   serif = [ "Noto Serif" emojiFont ];
   monospace = [
     "JetBrainsMono Nerd Font"
     "D2CodingLigature Nerd Font"
     "D2KodingLigature Nerd Font"
     emojiFont
   ];
   ```

   Never put it ahead of a primary font. Twemoji covers space, digits, `#`, and `*`, so it would take over ordinary text.
3. **List Twemoji last in Ghostty's own `font-family`.** Ghostty 1.3.1 picks glyphs from its configured `font-family` list and falls back to Noto Color Emoji, not to the fontconfig `emoji` alias (the `font-family` list in `home/h82/desktop/terminal.nix`).
4. **Prove it with `tests/emoji-font.nix`.** The check loads each configuration's built `/etc/fonts` (with `fonts.conf`'s absolute `/etc/fonts/conf.d` include redirected to the built tree, because the sandbox has no `/etc/fonts`) and models fallback as first-covering-font in `fc-match -s` order (the `first_cover_entry` helper in `tests/emoji-font.nix`). It reads the resolved file's tables with fonttools, because fontconfig's `color` property is true for the OpenType-SVG build too (the `ttx -l` step in `tests/emoji-font.nix`). The `ghostty-font` check in `flake.nix` requires Twemoji exactly once, as the last `font-family` entry.

## Why This Works

- Chromium/Skia, Qt, and GTK/Pango render CBDT and COLR color tables but, as observed here, not OpenType-SVG, so the SVG build degrades to its monochrome fallback glyphs everywhere except Firefox.
- A family in a generic alias's prefer list ranks ahead of the families fontconfig's own `60-latin.conf` adds, such as DejaVu Sans, so the first U+1F600-covering font in the built config's `fc-match -s` order becomes Twemoji.
- A **named** request such as `Noto Sans` or `Liberation Sans` still reaches DejaVu Sans first on the plain fallback path. fontconfig also compares the requested family against fonts' PostScript names, and `DejaVuSans` scores close to any "... Sans" request in a column that outranks every weak-bound family. That ordering was not changed. Apps that segment emoji-presentation characters request them with `lang=und-zsye`, and that request resolves to Twemoji for named and unknown families alike. A Pango render of 😀 in `Noto Sans` came out as color Twemoji. The check models this path with `fc-match "<family>:lang=und-zsye"`.

## Prevention

- Judge font fallback with `fc-match -s` plus a charset coverage set, not with `fc-match "<family>:charset=..."` and not with `fc-match emoji` alone.
- Before relying on a fontconfig `target="scan"` rule on NixOS, check that the rule is applied to the cached patterns. With the prebuilt cachedir in front, it will not be.
- When a check claims a color emoji font, read the font's tables (`ttx -l` showing `CBDT`/`CBLC` or `COLR`). Do not trust fontconfig's `color` property.
- Mutation-test emoji checks against the mutation that actually removes behavior:
  - Turning off `fonts.enableDefaultPackages` does not remove Noto Color Emoji, because `modules/nixos/system/agent-browser-deps.nix:39` installs it too.
  - Deleting Noto from `defaultFonts.emoji` changes nothing, because upstream `60-generic.conf` already lists it in the `emoji` alias.
  - A "Twemoji is the last `font-family`" assertion passed with a duplicate Twemoji placed first, until it also required exactly one occurrence.
- Residual: in Ghostty, emoji-presentation characters that a primary font already carries stay monochrome. ☕ comes from D2Coding and ⚡ from JetBrainsMono. The plan kept the primary fonts' glyphs on purpose, so the ⚡ Nerd Font glyph used in prompts stays.

## Related Issues

- [Ghostty CJK font fallback and D2Coding Nerd Font naming](ghostty-cjk-fallback-and-d2coding-nerd-font-naming.md): the same Ghostty `font-family` list and `ghostty-font` check, for Korean glyphs.
- Plan: `.compound-engineering/artifacts/plans/2026-10-06-1659-fix-twemoji-default-emoji-font-plan.md`.
