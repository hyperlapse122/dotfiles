---
title: Ghostty CJK font fallback and D2Coding Nerd Font naming convention
date: "2026-09-21"
category: integration-issues
module: Ghostty terminal & NixOS fonts
problem_type: integration_issue
component: typography
severity: low
symptoms:
  - "Korean monospace characters in Ghostty do not render using D2Coding"
  - "Ghostty renders Korean characters with system generic Noto Sans Mono CJK KR despite D2Coding installed"
root_cause: config_error
resolution_type: config_change
tags: ["ghostty", "fonts", "d2coding", "fontconfig", "korean"]
---

# Ghostty CJK font fallback and D2Coding Nerd Font naming convention

## Problem

Korean characters in Ghostty terminal failed to render using D2Coding font even after `nerd-fonts.d2coding` was packaged in NixOS and configured as a monospace font in fontconfig.

## Symptoms

Running `ghostty +show-face --string="한글"` showed Korean glyphs resolving to `Noto Sans Mono CJK KR` instead of D2Coding:

```text
U+D55C « 한 » found in face “Noto Sans Mono CJK KR”.
U+AE00 « 글 » found in face “Noto Sans Mono CJK KR”.
```

## What didn't work

Setting only `font-family = "JetBrainsMono Nerd Font"` in Ghostty config and relying on system fontconfig's second monospace entry failed. Ghostty queries fontconfig for missing codepoints; on Linux fontconfig matched generic system CJK monospace (`Noto Sans Mono CJK KR`) before finding D2Coding.

Additionally, upstream Nerd Fonts renamed D2Coding to `D2KodingLigature Nerd Font` (spelled with a `K`) due to SIL Open Font License Reserved Font Name (RFN) compliance, whereas local or legacy builds are often named `D2CodingLigature Nerd Font` (with a `C`). If an entry in Ghostty's `font-family` list cannot be matched by fontconfig, fontconfig's default pattern match returns generic system fonts, causing Ghostty to stop fallback evaluation prematurely.

## Solution

1. Declare `font-family` in Home Manager Ghostty settings as a list of fallback fonts:
   - Primary: `JetBrainsMono Nerd Font`
   - Fallback 1: `D2CodingLigature Nerd Font`
   - Fallback 2: `D2KodingLigature Nerd Font`
2. Register both `D2CodingLigature Nerd Font` and `D2KodingLigature Nerd Font` in `fonts.fontconfig.defaultFonts.monospace`.

Home Manager's Ghostty module enables `keyValueSettings.listsAsDuplicateKeys = true`, which outputs multiple `font-family = ...` lines to `$XDG_CONFIG_HOME/ghostty/config`, the native syntax Ghostty uses for preferred fallback fonts.

## Why this works

Ghostty processes multiple `font-family` directives in order. When rendering Latin and code ligatures, Ghostty uses `JetBrainsMono Nerd Font`. When encountering Korean codepoints (U+D55C, U+AE00), Ghostty checks fallback fonts sequentially and matches `D2CodingLigature Nerd Font` or `D2KodingLigature Nerd Font`.

Placing `D2CodingLigature Nerd Font` before `D2KodingLigature Nerd Font` ensures compatibility across both existing user fonts (`~/.local/share/fonts/`) and fresh NixOS systems with `nerd-fonts.d2coding`.

## Prevention

Use `ghostty +show-face` to test character resolution:

```sh
CONFIG_PATH=$(nix-build --impure --expr 'let f = builtins.getFlake (toString ./.); in f.nixosConfigurations.MS-7D91-VM.config.home-manager.users.h82.xdg.configFile."ghostty/config".source' --no-out-link)
ghostty +show-face --config-file="$CONFIG_PATH" --string="한글"
```

Flake check `checks.x86_64-linux.ghostty-font` in `flake.nix` verifies that the generated `ghostty/config` and fontconfig monospace defaults retain both D2Coding font entries. It also requires `Twitter Color Emoji` exactly once, as the last `font-family` entry, and runs for every configuration.
