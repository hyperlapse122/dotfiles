{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; }) forEveryUser assertUserPackage;
  assertConfiguration =
    entry:
    let
      profile = entry.user.home.path or null;
    in
    pkgs.lib.concatMapStrings
      (
        pname:
        assertUserPackage {
          inherit pname;
          executables = [ pname ];
          desktopEntries = [ ];
        } entry
        + (
          if profile == null then
            ''
              echo 'missing user profile on ${entry.name}' >&2
              fail=1
            ''
          else
            ''
              if [ ! -x ${profile}/bin/${pname} ] || ! env -i HOME="$TMPDIR" PATH=${profile}/bin ${profile}/bin/${pname} --version; then
                echo 'installed ${pname} runtime failed on ${entry.name}' >&2
                fail=1
              fi
            ''
        )
      )
      [
        "python3"
        "uv"
      ];
in
pkgs.runCommand "python3-runtime-tests" { } ''
  ${forEveryUser assertConfiguration}
  touch $out
''
