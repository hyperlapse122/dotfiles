#!/usr/bin/env bash
# scripts/config-kde.sh
#
# Combined KDE Plasma 6 user-side configuration. Three independent steps,
# each guarded so a missing prerequisite skips that step alone (returning 0)
# without taking the whole script down:
#
#   1. fonts    - kwriteconfig6 -> ~/.config/kdeglobals
#                 sans (font, menuFont, toolBarFont, smallestReadableFont,
#                       [WM] activeFont)            -> Pretendard
#                 mono (fixed)                      -> JetBrainsMono Nerd Font
#                 Errors (exit 1) when a requested font isn't installed - run
#                 scripts/install-fonts.sh first.
#
#   2. touchpad - busctl --user -> KWin's org.kde.KWin.InputDeviceManager
#                 For each touchpad whose libinput name appears in
#                 TOUCHPAD_TARGET_NAMES:
#                   naturalScroll          -> true
#                   clickMethodClickfinger -> true
#                   clickMethodAreas       -> false
#                 Other touchpads (e.g. external USB trackpads) untouched.
#                 Skips cleanly when busctl is missing or no Plasma session
#                 owns org.kde.KWin (arch-chroot, headless, GNOME, ...).
#
#   3. panel    - kwriteconfig6 -> ~/.config/plasma-org.kde.plasma.desktop-appletsrc
#                 For every org.kde.plasma.icontasks / org.kde.plasma.taskmanager
#                 applet at the panel level (NOT under systemtray):
#                   [Configuration][General] groupingStrategy = 0
#                 i.e. "Do not group" / TasksModel::GroupDisabled. Matches
#                 the dropdown labelled "Group: Do not group" in the
#                 Icons-Only Task Manager configuration dialog.
#
# Single-platform (Linux only) by design. KDE Plasma is a Linux desktop
# environment; macOS uses native font/touchpad APIs and Windows uses the
# registry, so there is nothing equivalent to configure on either. No .ps1
# counterpart per the script-parity exception in ../AGENTS.md.
#
# MUST run as the user owning the Plasma session (touchpad uses session DBus,
# fonts/panel write to ~/.config); never invoke under sudo.
#
# Re-runnable: every write is idempotent.
#
# After running, restart plasmashell or log out/in to fully apply font and
# panel changes. Touchpad changes apply live via DBus.

set -euo pipefail

# ---------------------------------------------------------------------------
# Common: hard-skip on non-KDE systems (no plasmashell binary anywhere).
# Used by every step as the "is this a KDE box?" probe.
# ---------------------------------------------------------------------------

if ! command -v plasmashell >/dev/null 2>&1; then
  printf 'config-kde.sh: plasmashell not found (non-KDE system), skipping.\n'
  exit 0
fi

# ===========================================================================
# Step 1: fonts
# ===========================================================================

configure_fonts() {
  printf 'config-kde.sh: [fonts] configuring KDE display fonts...\n'

  if ! command -v kwriteconfig6 >/dev/null 2>&1; then
    printf '  kwriteconfig6 not found, skipping.\n'
    return 0
  fi
  if ! command -v fc-match >/dev/null 2>&1; then
    printf '  fc-match not found, cannot verify font availability.\n' >&2
    return 1
  fi

  local SANS="Pretendard"
  local MONO="JetBrainsMono Nerd Font"

  # fc-match always returns SOMETHING (closest fallback). Compare the
  # resolved family name to the requested family name to detect an actual
  # install.
  _require_font() {
    local family="$1"
    local matched
    matched="$(fc-match -f '%{family[0]}' "$family")"
    if [[ "$matched" != "$family" ]]; then
      printf '  font "%s" not installed (fc-match -> "%s"). Run scripts/install-fonts.sh first.\n' \
        "$family" "$matched" >&2
      return 1
    fi
  }

  _require_font "$SANS"
  _require_font "$MONO"

  # Plasma 6 / Qt 6 kdeglobals font value format (16 comma-separated fields):
  #   family,pointSize,pixelSize,styleHint,weight,italic,underline,strikeOut,
  #   fixedPitch,rawMode,styleStrategy,stretch,(unused)x3,preferTypoLineMetrics
  # Weight 400 = Regular, styleHint 5 = AnyStyle. 10pt for general fonts,
  # 8pt for smallestReadableFont to match KDE defaults.
  _font_value() { printf '%s,%d,-1,5,400,0,0,0,0,0,0,0,0,0,0,1' "$1" "$2"; }

  _set_general() {
    local key="$1" value="$2"
    kwriteconfig6 --file kdeglobals --group General --key "$key" "$value"
    printf '  set [General] %-22s = %s\n' "$key" "$value"
  }

  _set_general font                 "$(_font_value "$SANS" 10)"
  _set_general menuFont             "$(_font_value "$SANS" 10)"
  _set_general toolBarFont          "$(_font_value "$SANS" 10)"
  _set_general fixed                "$(_font_value "$MONO" 10)"
  _set_general smallestReadableFont "$(_font_value "$SANS"  8)"

  # Window-title font lives under [WM].
  local wm_active
  wm_active="$(_font_value "$SANS" 10)"
  kwriteconfig6 --file kdeglobals --group WM --key activeFont "$wm_active"
  printf '  set [WM]      %-22s = %s\n' "activeFont" "$wm_active"
}

# ===========================================================================
# Step 2: touchpad (libinput natural scroll + clickfinger via KWin DBus)
# ===========================================================================

# Only touchpads whose libinput `name` exactly matches an entry here are
# configured. Add more names (one per line, no trailing whitespace) to
# extend coverage to additional hosts.
TOUCHPAD_TARGET_NAMES=(
  'SynPS/2 Synaptics TouchPad'
)

configure_touchpad() {
  printf 'config-kde.sh: [touchpad] configuring KDE touchpad(s)...\n'

  if ! command -v busctl >/dev/null 2>&1; then
    printf '  busctl not found, skipping.\n'
    return 0
  fi

  local SERVICE='org.kde.KWin'
  local MGR_PATH='/org/kde/KWin/InputDevice'
  local IFACE_MGR='org.kde.KWin.InputDeviceManager'
  local IFACE_DEV='org.kde.KWin.InputDevice'

  # busctl get-property prints "<sig> <value>", e.g. `b true` or `s "foo"`.
  # Strip the signature prefix; callers compare against `true`/`false` for
  # bools and strip the surrounding quotes themselves for strings.
  _dbus_get() {
    local path="$1" prop="$2"
    busctl --user get-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" 2>/dev/null \
      | awk '{ $1=""; sub(/^ /, ""); print }'
  }

  _dbus_set_b() {
    local path="$1" prop="$2" value="$3"
    busctl --user set-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" b "$value"
    printf '    set %-26s = %s\n' "$prop" "$value"
  }

  # Probe org.kde.KWin via the InputDeviceManager and grab the sysnames in
  # the same call. busctl exits non-zero if the service isn't on the session
  # bus, which is the normal case for non-Plasma / headless / arch-chroot
  # environments - skip cleanly.
  #
  # (`busctl --user list` cannot be used as a precheck: it filters its
  # output differently when stdout is not a TTY and hides well-known names
  # in scripts.)
  local raw
  if ! raw="$(busctl --user get-property "$SERVICE" "$MGR_PATH" "$IFACE_MGR" devicesSysNames 2>/dev/null)"; then
    printf '  org.kde.KWin not reachable on session bus (no active Plasma session?), skipping.\n'
    return 0
  fi

  # busctl emits `as N "event0" "event1" ...`; just grab everything between
  # double-quotes.
  local sysnames=()
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && sysnames+=("$name")
  done < <(printf '%s\n' "$raw" | grep -oE '"[^"]+"' | tr -d '"')

  local count=0
  local sn path is_touchpad name_quoted matched target
  for sn in "${sysnames[@]}"; do
    path="$MGR_PATH/$sn"
    is_touchpad="$(_dbus_get "$path" touchpad)"
    [[ "$is_touchpad" == "true" ]] || continue

    name_quoted="$(_dbus_get "$path" name)"
    name="${name_quoted#\"}"
    name="${name%\"}"

    # Skip touchpads not in the allow-list.
    matched=0
    for target in "${TOUCHPAD_TARGET_NAMES[@]}"; do
      if [[ "$name" == "$target" ]]; then
        matched=1
        break
      fi
    done
    if [[ "$matched" -eq 0 ]]; then
      printf '  skip: %s (%s) — not in TOUCHPAD_TARGET_NAMES\n' "$name" "$sn"
      continue
    fi

    printf '  touchpad: %s (%s)\n' "$name" "$sn"

    # Natural scroll (two-finger drag follows content).
    if [[ "$(_dbus_get "$path" supportsNaturalScroll)" == "true" ]]; then
      _dbus_set_b "$path" naturalScroll true
    else
      printf '    skip naturalScroll: not supported by device\n'
    fi

    # Clickfinger (two-finger = right, three-finger = middle). The two
    # click methods are mutually exclusive in libinput; set both explicitly
    # so the final state is deterministic regardless of the previous value.
    if [[ "$(_dbus_get "$path" supportsClickMethodClickfinger)" == "true" ]]; then
      _dbus_set_b "$path" clickMethodClickfinger true
      if [[ "$(_dbus_get "$path" supportsClickMethodAreas)" == "true" ]]; then
        _dbus_set_b "$path" clickMethodAreas false
      fi
    else
      printf '    skip clickMethodClickfinger: not supported by device\n'
    fi

    count=$((count + 1))
  done

  if [[ "$count" -eq 0 ]]; then
    printf '  no touchpad in TOUCHPAD_TARGET_NAMES present on this session, skipping.\n'
    return 0
  fi

  printf '  configured %d touchpad(s).\n' "$count"
}

# ===========================================================================
# Step 3: panel (disable task manager grouping)
# ===========================================================================
#
# Sets `groupingStrategy = 0` (TasksModel::GroupDisabled, "Do not group") on
# every panel-level icontasks / taskmanager applet. Default is 1
# (GroupApplications, "By program name"), which collapses N windows of the
# same app into a single panel entry behind a click-through menu - we want
# one entry per window.
#
# CAVEAT: ~/.config/plasma-org.kde.plasma.desktop-appletsrc is owned by a
# running plasmashell. plasmashell holds it in memory, only re-reads on
# startup, and re-writes it whenever something changes via the UI. To make
# this take effect cleanly:
#   1. Run this script BEFORE plasmashell first starts (e.g. arch-chroot
#      install, fresh user account); or
#   2. Run it, then restart plasmashell (kquitapp6 plasmashell ; kstart
#      plasmashell) before touching the panel via the GUI - otherwise
#      plasmashell's stale in-memory state will overwrite our edit.
# Either way the write is idempotent so re-running is safe.

configure_panel() {
  printf 'config-kde.sh: [panel] disabling task manager grouping...\n'

  if ! command -v kwriteconfig6 >/dev/null 2>&1 || ! command -v kreadconfig6 >/dev/null 2>&1; then
    printf '  kwriteconfig6/kreadconfig6 not found, skipping.\n'
    return 0
  fi

  local file="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
  if [[ ! -f "$file" ]]; then
    printf '  %s not found (no Plasma session has ever started?), skipping.\n' "$file"
    return 0
  fi

  # Find icontasks/taskmanager applets at the panel level. The anchored
  # regex matches `[Containments][N][Applets][M]` exactly, excluding the
  # nested `[Containments][N][Applets][M][Applets][L]` shape used by
  # systemtray subapplets - we don't want to flip grouping on a stray
  # systray task indicator (none currently exist, but be explicit).
  local count=0
  local containment applet plugin
  while IFS=':' read -r containment applet; do
    plugin="$(kreadconfig6 --file "$file" \
      --group Containments --group "$containment" \
      --group Applets --group "$applet" \
      --key plugin)"
    case "$plugin" in
      org.kde.plasma.icontasks|org.kde.plasma.taskmanager) ;;
      *) continue ;;
    esac
    kwriteconfig6 --file "$file" \
      --group Containments --group "$containment" \
      --group Applets --group "$applet" \
      --group Configuration --group General \
      --key groupingStrategy 0
    printf '  set [Containments/%s/Applets/%s] (%s) groupingStrategy = 0\n' \
      "$containment" "$applet" "$plugin"
    count=$((count + 1))
  done < <(grep -oE '^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$' "$file" \
            | sed -E 's/^\[Containments\]\[([0-9]+)\]\[Applets\]\[([0-9]+)\]$/\1:\2/')

  if [[ "$count" -eq 0 ]]; then
    printf '  no icontasks/taskmanager applet found in panel config, skipping.\n'
    return 0
  fi

  printf '  configured %d task manager applet(s).\n' "$count"
}

# ===========================================================================
# Run all steps. Each is independent; set -e propagates any real failure.
# ===========================================================================

configure_fonts
configure_touchpad
configure_panel

printf 'config-kde.sh: done. Restart plasmashell or re-login to fully apply font and panel changes.\n'
