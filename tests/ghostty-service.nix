{ pkgs, self }:
# Ghostty sends READY=1 before it installs its SIGUSR2 handler, and
# systemd 262 refuses a notify-reload service whose main process has
# no reload-signal handler at READY. The effective unit, read from
# the materialized base unit and its drop-ins in systemd's order,
# must therefore be Type=notify and reload through ExecReload.
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; }) forEveryConfiguration;
  assertConfiguration =
    entry:
    let
      unitDir = if entry.user ? home-files then "${entry.user.home-files}/.config/systemd/user" else null;
      unit = "app-com.mitchellh.ghostty.service";
    in
    ''
      ${pkgs.lib.optionalString (unitDir == null) ''
        echo 'missing Home Manager files on ${entry.name}' >&2
        fail=1
      ''}
      ${pkgs.lib.optionalString (unitDir != null) ''
        dir=${pkgs.lib.escapeShellArg unitDir}
        if [ ! -f "$dir/${unit}" ]; then
          echo 'missing ${unit} on ${entry.name}' >&2
          fail=1
        else
          files=("$dir/${unit}")
          if [ -d "$dir/${unit}.d" ]; then
            while IFS= read -r f; do files+=("$f"); done \
              < <(find -L "$dir/${unit}.d" -maxdepth 1 -name '*.conf' | LC_ALL=C sort)
          fi
          type=$(cat "''${files[@]}" | grep '^Type=' | tail -n 1)
          if [ "$type" != 'Type=notify' ]; then
            echo "effective ${unit} $type is not Type=notify on ${entry.name}" >&2
            fail=1
          fi
          reload=$(cat "''${files[@]}" | grep '^ExecReload=' | tail -n 1)
          read -r kill signal pid <<<"''${reload#ExecReload=}"
          if [ ! -x "$kill" ] || [ "$signal" != -USR2 ] || [ "$pid" != '$MAINPID' ]; then
            echo "effective ${unit} '$reload' does not send SIGUSR2 to the main process on ${entry.name}" >&2
            fail=1
          fi
        fi
      ''}
    '';
in
pkgs.runCommand "ghostty-service-tests"
  {
    nativeBuildInputs = [
      pkgs.findutils
      pkgs.gnugrep
    ];
  }
  ''
    ${forEveryConfiguration assertConfiguration}
    touch $out
  ''
