{ pkgs, lib, ... }:
let
  configureInputScript = pkgs.writeShellScriptBin "configure-kde-input-devices" ''
    set -euo pipefail
    export PATH="${
      lib.makeBinPath [
        pkgs.systemd
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gawk
      ]
    }:$PATH"

    SERVICE='org.kde.KWin'
    MGR_PATH='/org/kde/KWin/InputDevice'
    IFACE_MGR='org.kde.KWin.InputDeviceManager'
    IFACE_DEV='org.kde.KWin.InputDevice'

    _dbus_get() {
      local path="$1" prop="$2"
      busctl --user get-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" 2>/dev/null \
        | awk '{ $1=""; sub(/^ /, ""); print }'
    }

    _dbus_set_b() {
      local path="$1" prop="$2" value="$3"
      busctl --user set-property "$SERVICE" "$path" "$IFACE_DEV" "$prop" b "$value"
    }

    raw="$(busctl --user get-property "$SERVICE" "$MGR_PATH" "$IFACE_MGR" devicesSysNames 2>/dev/null || true)"
    if [ -z "$raw" ]; then
      exit 0
    fi

    sysnames=()
    while IFS= read -r name; do
      [ -n "$name" ] && sysnames+=("$name")
    done < <(printf '%s\n' "$raw" | grep -oE '"[^"]+"' | tr -d '"')

    for sn in "''${sysnames[@]}"; do
      path="$MGR_PATH/$sn"
      is_touchpad="$(_dbus_get "$path" touchpad)"

      if [ "$is_touchpad" = "true" ]; then
        if [ "$(_dbus_get "$path" supportsNaturalScroll)" = "true" ]; then
          _dbus_set_b "$path" naturalScroll true
        fi
        tap_finger_count="$(_dbus_get "$path" tapFingerCount)"
        if [ -n "$tap_finger_count" ] && [ "$tap_finger_count" != "0" ]; then
          _dbus_set_b "$path" tapToClick true
        fi
        if [ "$(_dbus_get "$path" supportsClickMethodClickfinger)" = "true" ]; then
          _dbus_set_b "$path" clickMethodClickfinger true
          if [ "$(_dbus_get "$path" supportsClickMethodAreas)" = "true" ]; then
            _dbus_set_b "$path" clickMethodAreas false
          fi
        fi
      else
        if [ "$(_dbus_get "$path" pointer)" = "true" ]; then
          name_quoted="$(_dbus_get "$path" name)"
          name="''${name_quoted#\"}"
          name="''${name%\"}"

          case "$name" in
            *TrackPoint*|*Trackpoint*|TPPS/2*)
              if [ "$(_dbus_get "$path" supportsNaturalScroll)" = "true" ]; then
                _dbus_set_b "$path" naturalScroll true
              fi
              if [ "$(_dbus_get "$path" supportsMiddleEmulation)" = "true" ]; then
                _dbus_set_b "$path" middleEmulation true
              fi
              if [ "$(_dbus_get "$path" supportsScrollOnButtonDown)" = "true" ]; then
                _dbus_set_b "$path" scrollOnButtonDown true
              fi
              ;;
          esac
        fi
      fi
    done
  '';
in
{
  home.packages = [ configureInputScript ];

  xdg.configFile."autostart/configure-kde-input-devices.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Configure KDE Input Devices
    Exec=${configureInputScript}/bin/configure-kde-input-devices
    Hidden=false
    NoDisplay=true
    X-KDE-autostart-phase=2
  '';

  home.activation.kdeInputDevices = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${configureInputScript}/bin/configure-kde-input-devices" ]; then
      ${configureInputScript}/bin/configure-kde-input-devices || true
    fi
  '';
}
