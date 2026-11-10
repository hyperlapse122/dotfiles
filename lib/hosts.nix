# The hosts under a hosts/ directory, split by kind. A directory without
# host.nix is a NixOS host; one with host.nix is the kind its `kind` field
# names, `darwin`. Host discovery in flake.nix and every check that
# enumerates hosts share this, so they all agree on which hosts have a NixOS
# system, and with it a disk layout.
#
#   hosts = import ./lib/hosts.nix { inherit lib; } ./hosts;
#   -> { all, nixos, darwin, withVariants }
#
# withVariants build hostName gives the production and bootstrap output of one
# host as name/value pairs for listToAttrs, calling build hostName bootstrap.
{ lib }:
dir:
let
  all = import ../tests/lib/directories.nix { inherit lib; } dir;
  hasHostFile = hostName: builtins.pathExists (dir + "/${hostName}/host.nix");
  isDarwin =
    hostName:
    if !hasHostFile hostName then
      false
    else
      let
        kind = (import (dir + "/${hostName}/host.nix")).kind or null;
      in
      if kind == "darwin" then true else throw "unsupported host kind: ${toString kind}";
in
{
  inherit all;
  nixos = lib.filter (hostName: !hasHostFile hostName) all;
  darwin = lib.filter isDarwin all;

  withVariants =
    build: hostName:
    map
      (bootstrap: {
        name = if bootstrap then "${hostName}-bootstrap" else hostName;
        value = build hostName bootstrap;
      })
      [
        false
        true
      ];
}
