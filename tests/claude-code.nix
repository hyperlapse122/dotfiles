{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; })
    forEveryConfiguration
    userPackageOf
    assertUserPackage
    ;
  # nixpkgs checks the binary against its version attribute. Also compare that version to our pin.
  pinnedVersion =
    (builtins.fromJSON (builtins.readFile ../packages/claude-code-manifest.json)).version;
  assertConfiguration =
    entry:
    let
      claudePkg = userPackageOf "claude-code" entry;
      versionMismatch =
        pkgs.lib.optionalString (claudePkg != null && claudePkg.version != pinnedVersion)
          ''
            echo "claude-code on ${entry.name} is built from version '${claudePkg.version}', expected pin ${pinnedVersion}" >&2
            fail=1
          '';
    in
    ''
      ${assertUserPackage {
        pname = "claude-code";
        executables = [ "claude" ];
        desktopEntries = [ ];
      } entry}
      ${versionMismatch}
    '';
in
pkgs.runCommand "claude-code-tests" { } ''
  set -x
  ${forEveryConfiguration assertConfiguration}
  touch $out
''
