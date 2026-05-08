#!/usr/bin/env bash
# scripts/configure-kde-touchpad.sh
#
# Configures the libinput touchpad named in $TARGET_NAME (currently the
# "SynPS/2 Synaptics TouchPad" found on the author's ThinkPad-class hardware):
#
#   naturalScroll          -> true   (two-finger drag matches content direction)
#   clickMethodClickfinger -> true   (two-finger tap = right-click,
#                                     three-finger tap = middle-click)
#   clickMethodAreas       -> false  (disables the default "press the bottom-
#                                     right corner" right-click method, which
#                                     is mutually exclusive with clickfinger)
#
# Other touchpads attached to the same session (e.g. external USB trackpads)
# are intentionally left untouched. Add more names to TARGET_NAMES below
# when you want this to cover additional devices.
#
# Works by talking to KWin's `org.kde.KWin.InputDeviceManager` on the user
# session bus, enumerating devices whose `touchpad` property is true, matching
# the `name` property against TARGET_NAMES, and setting the writable libinput
# properties via `busctl set-property`. KWin persists the change to
# ~/.config/kcminputrc automatically; the new values also apply live to the
# running session.
#
# Properties with a corresponding `supports*` flag are checked before being
# set, so a touchpad that only supports button-area clicks (rare) is left
# alone instead of erroring.
#
# Exit conditions:
#   busctl missing                   -> skip (exit 0)
#   plasmashell missing              -> skip (exit 0): non-KDE system
#   org.kde.KWin not on session bus  -> skip (exit 0): no active Plasma session
#   no touchpad in TARGET_NAMES      -> skip (exit 0)
#
# Single-platform (Linux only) by design. KDE Plasma is a Linux desktop
# environment; macOS and Windows manage touchpads through their own native
# APIs. No .ps1 counterpart per the script-parity exception in ../AGENTS.md.
#
# MUST run as the user owning the Plasma session (session DBus is per-user);
# never invoke under `sudo`. Re-runnable: each set-property is idempotent.

set -euo pipefail

if ! command -v busctl >/dev/null 2>&1; then
  printf 'configure-kde-touchpad.sh: busctl not found, skipping.\n'
  exit 0
fi

if ! command -v plasmashell >/dev/null 2>&1; then
  printf 'configure-kde-touchpad.sh: plasmashell not found (non-KDE system), skipping.\n'
  exit 0
fi

readonly SERVICE='org.kde.KWin'
readonly MGR_PATH='/org/kde/KWin/InputDevice'
readonly IFACE_MGR='org.kde.KWin.InputDeviceManager'
readonly IFACE_DEV='org.kde.KWin.InputDevice'

# Only touchpads whose libinput `name` exactly matches an entry here are
# configured. Add more names (one per line, no trailing whitespace) to extend
# coverage to additional hosts.
TARGET_NAMES=(
  'SynPS/2 Synaptics TouchPad'
)

# busctl get-property prints "<sig> <value>", e.g. `b true` or `s "foo"`.
# Strip the signature prefix; callers compare against `true`/`false` for bools
# and strip the surrounding quotes themselves for strings.
dbus_get() {
  local path="$1" prop="$2"
  busctl --user get-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" 2>/dev/null \
    | awk '{ $1=""; sub(/^ /, ""); print }'
}

dbus_set_b() {
  local path="$1" prop="$2" value="$3"
  busctl --user set-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" b "$value"
  printf '    set %-26s = %s\n' "$prop" "$value"
}

# Probe org.kde.KWin via the InputDeviceManager and grab the sysnames in the
# same call. busctl exits non-zero if the service isn't on the session bus,
# which is the normal case for non-Plasma / headless / arch-chroot
# environments - skip cleanly.
#
# (`busctl --user list` cannot be used as a precheck: it filters its output
# differently when stdout is not a TTY and hides well-known names in scripts.)
if ! raw="$(busctl --user get-property "$SERVICE" "$MGR_PATH" "$IFACE_MGR" devicesSysNames 2>/dev/null)"; then
  printf 'configure-kde-touchpad.sh: org.kde.KWin not reachable on session bus (no active Plasma session?), skipping.\n'
  exit 0
fi

# busctl emits `as N "event0" "event1" ...`; just grab everything between
# double-quotes.

sysnames=()
while IFS= read -r name; do
  [[ -n "$name" ]] && sysnames+=("$name")
done < <(printf '%s\n' "$raw" | grep -oE '"[^"]+"' | tr -d '"')

count=0
for sn in "${sysnames[@]}"; do
  path="$MGR_PATH/$sn"
  is_touchpad="$(dbus_get "$path" touchpad)"
  [[ "$is_touchpad" == "true" ]] || continue

  name_quoted="$(dbus_get "$path" name)"
  name="${name_quoted#\"}"
  name="${name%\"}"

  # Skip touchpads not in the allow-list.
  matched=0
  for target in "${TARGET_NAMES[@]}"; do
    if [[ "$name" == "$target" ]]; then
      matched=1
      break
    fi
  done
  if [[ "$matched" -eq 0 ]]; then
    printf '  skip: %s (%s) — not in TARGET_NAMES\n' "$name" "$sn"
    continue
  fi

  printf '  touchpad: %s (%s)\n' "$name" "$sn"

  # Natural scroll (two-finger drag follows content).
  if [[ "$(dbus_get "$path" supportsNaturalScroll)" == "true" ]]; then
    dbus_set_b "$path" naturalScroll true
  else
    printf '    skip naturalScroll: not supported by device\n'
  fi

  # Clickfinger (two-finger = right, three-finger = middle). The two click
  # methods are mutually exclusive in libinput; set both explicitly so the
  # final state is deterministic regardless of the previous value.
  if [[ "$(dbus_get "$path" supportsClickMethodClickfinger)" == "true" ]]; then
    dbus_set_b "$path" clickMethodClickfinger true
    if [[ "$(dbus_get "$path" supportsClickMethodAreas)" == "true" ]]; then
      dbus_set_b "$path" clickMethodAreas false
    fi
  else
    printf '    skip clickMethodClickfinger: not supported by device\n'
  fi

  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  printf 'configure-kde-touchpad.sh: no touchpad in TARGET_NAMES present on this session, skipping.\n'
  exit 0
fi

printf 'configure-kde-touchpad.sh: configured %d touchpad(s).\n' "$count"
