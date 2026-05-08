#!/usr/bin/env bash
# scripts/configure-kde-fonts.sh
#
# Sets KDE Plasma 6 display fonts in ~/.config/kdeglobals via kwriteconfig6:
#
#   sans-serif (font, menuFont, toolBarFont, smallestReadableFont,
#               [WM] activeFont)         -> Pretendard
#   monospace  (fixed)                   -> JetBrainsMono Nerd Font
#
# Exit conditions:
#   kwriteconfig6 missing       -> skip (exit 0): "no tool for modifying KDE options"
#   plasmashell missing         -> skip (exit 0): non-KDE system
#   fc-match missing            -> error (exit 1)
#   requested font not installed (fc-match resolves to a different family)
#                               -> error (exit 1) so misconfiguration surfaces
#                                  (run scripts/install-fonts.sh first)
#
# Single-platform (Linux only) by design. KDE Plasma is a Linux desktop
# environment; macOS uses native font APIs and Windows uses the registry, so
# there is nothing equivalent to configure on either. No .ps1 counterpart per
# the script-parity exception in ../AGENTS.md.
#
# Re-runnable: kwriteconfig6 overwrites existing values atomically.
# After running, restart plasmashell (or log out/in) to fully apply.

set -euo pipefail

if ! command -v kwriteconfig6 >/dev/null 2>&1; then
  printf 'configure-kde-fonts.sh: kwriteconfig6 not found, skipping.\n'
  exit 0
fi

if ! command -v plasmashell >/dev/null 2>&1; then
  printf 'configure-kde-fonts.sh: plasmashell not found (non-KDE system), skipping.\n'
  exit 0
fi

if ! command -v fc-match >/dev/null 2>&1; then
  printf 'configure-kde-fonts.sh: fc-match not found, cannot verify font availability.\n' >&2
  exit 1
fi

SANS="Pretendard"
MONO="JetBrainsMono Nerd Font"

# fc-match always returns SOMETHING (closest fallback). Compare the resolved
# family name to the requested family name to detect an actual install.
require_font() {
  local family="$1"
  local matched
  matched="$(fc-match -f '%{family[0]}' "$family")"
  if [[ "$matched" != "$family" ]]; then
    printf 'configure-kde-fonts.sh: font "%s" not installed (fc-match -> "%s"). Run scripts/install-fonts.sh first.\n' \
      "$family" "$matched" >&2
    exit 1
  fi
}

require_font "$SANS"
require_font "$MONO"

# Plasma 6 / Qt 6 kdeglobals font value format (16 comma-separated fields):
#   family,pointSize,pixelSize,styleHint,weight,italic,underline,strikeOut,
#   fixedPitch,rawMode,styleStrategy,stretch,(unused)x3,preferTypoLineMetrics
# Weight 400 = Regular, styleHint 5 = AnyStyle. 10pt for general fonts, 8pt
# for smallestReadableFont to match KDE defaults.
font_value() { printf '%s,%d,-1,5,400,0,0,0,0,0,0,0,0,0,0,1' "$1" "$2"; }

set_general() {
  local key="$1" value="$2"
  kwriteconfig6 --file kdeglobals --group General --key "$key" "$value"
  printf '  set [General] %-22s = %s\n' "$key" "$value"
}

set_general font                 "$(font_value "$SANS" 10)"
set_general menuFont             "$(font_value "$SANS" 10)"
set_general toolBarFont          "$(font_value "$SANS" 10)"
set_general fixed                "$(font_value "$MONO" 10)"
set_general smallestReadableFont "$(font_value "$SANS"  8)"

# Window-title font lives under [WM].
wm_active="$(font_value "$SANS" 10)"
kwriteconfig6 --file kdeglobals --group WM --key activeFont "$wm_active"
printf '  set [WM]      %-22s = %s\n' "activeFont" "$wm_active"

printf 'configure-kde-fonts.sh: done. Restart plasmashell or re-login to fully apply.\n'
