/*
  Check interface:

    import ./tests/wireplumber-bluetooth.nix { inherit pkgs self; }

  Asserts that every configuration makes the WirePlumber user service load
  bluetooth.autoswitch-to-headset-profile = false, declared in
  modules/nixos/hardware/bluetooth-audio.nix. The check reads the conf.d
  fragments under the service's XDG_DATA_DIRS, the search path WirePlumber
  actually loads, rather than the extraConfig option value.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike:
  - the wireplumber user service stays enabled.
  - at least one fragment sets the key to false in a wireplumber.settings
    section, whatever the fragment file is named.
  - no fragment sets the key to true, in either the compact JSON extraConfig
    renders or the SPA-JSON a hand-written configPackages fragment uses.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  assertEntry =
    entry:
    let
      service = entry.config.systemd.user.services.wireplumber or { };
      dataDirs = service.environment.XDG_DATA_DIRS or "";
    in
    ''
      if [ "${pkgs.lib.boolToString (service.enable or false)}" != "true" ]; then
        echo "${entry.name}: the wireplumber user service is not enabled" >&2
        failed=1
      fi

      data_dirs='${dataDirs}'
      if [ -z "$data_dirs" ]; then
        echo "${entry.name}: the wireplumber user service has no XDG_DATA_DIRS" >&2
        failed=1
      else
        found_false=0
        IFS=: read -r -a dirs <<< "$data_dirs"
        for dir in "''${dirs[@]}"; do
          for fragment in "$dir"/wireplumber/wireplumber.conf.d/*.conf; do
            [ -e "$fragment" ] || continue
            if grep -Eq 'bluetooth\.autoswitch-to-headset-profile"?[[:space:]]*[:=][[:space:]]*true' "$fragment"; then
              echo "${entry.name}: $fragment sets bluetooth.autoswitch-to-headset-profile to true" >&2
              failed=1
            fi
            if grep -Eq '^wireplumber\.settings = .*"bluetooth\.autoswitch-to-headset-profile":false' "$fragment"; then
              found_false=1
            fi
          done
        done

        if [ "$found_false" != 1 ]; then
          echo "${entry.name}: no wireplumber.conf.d fragment sets bluetooth.autoswitch-to-headset-profile to false" >&2
          failed=1
        fi
      fi
    '';
in
pkgs.runCommand "wireplumber-bluetooth-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -x
  ${configurations.guard}
  failed=0

  ${pkgs.lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
