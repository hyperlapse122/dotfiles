/*
  Check interface:

    import ./tests/user-avatar.nix { inherit pkgs self; }

  Asserts that every configuration deploys the user avatar where each
  consumer reads it.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike:
  - Home Manager's built home files carry ~/.face and ~/.face.icon with the asset's bytes
    (read by AccountsService for System Settings and by the Plasma session).
  - The system profile carries share/sddm/faces/h82.face.icon with the asset's bytes
    (read by the SDDM greeter, which cannot enter the mode-700 home directory).

  The comparisons are byte-for-byte, so they do not depend on the asset's store path.
  Home files are interpolated only when the user generation exists, so a
  removed user fails inside the builder rather than during evaluation. The
  builder collects every failure before it exits, so one red build names every
  affected configuration.
*/
{ pkgs, self }:
let
  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  asset = ../home/h82/assets/face.png;

  assertHomeFiles =
    entry:
    if entry.user ? home-files then
      ''
        for name in .face .face.icon; do
          if [ ! -e "${entry.user.home-files}/$name" ]; then
            echo "Home Manager does not deploy ~/$name on ${entry.name}" >&2
            failed=1
          elif ! cmp -s "${entry.user.home-files}/$name" "${asset}"; then
            echo "~/$name on ${entry.name} differs from home/h82/assets/face.png" >&2
            failed=1
          fi
        done
      ''
    else
      ''
        echo "${entry.name}: the h82 Home Manager generation is missing" >&2
        failed=1
      '';

  assertEntry = entry: ''
    ${assertHomeFiles entry}

    sddmFace="${entry.config.system.path}/share/sddm/faces/h82.face.icon"
    if [ ! -e "$sddmFace" ]; then
      echo "system profile lacks share/sddm/faces/h82.face.icon on ${entry.name}" >&2
      failed=1
    elif ! cmp -s "$sddmFace" "${asset}"; then
      echo "SDDM face for h82 on ${entry.name} differs from home/h82/assets/face.png" >&2
      failed=1
    fi
  '';
in
pkgs.runCommand "user-avatar-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  set -x
  ${configurations.guard}
  failed=0

  ${pkgs.lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
