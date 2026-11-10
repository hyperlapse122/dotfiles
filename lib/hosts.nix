# The hosts under a hosts/ directory, split by kind. A directory without
# host.nix is a NixOS host; one with host.nix is the kind its `kind` field
# names, `linux` or `darwin`. Host discovery in flake.nix and every check that
# enumerates hosts share this, so they all agree on which hosts have a NixOS
# system, and with it a disk layout.
#
#   hosts = import ./lib/hosts.nix { inherit lib; } ./hosts;
#   -> { all, nixos, linux, darwin, withVariants }
#
# withVariants build hostName gives the production and bootstrap output of one
# host as name/value pairs for listToAttrs, calling build hostName bootstrap.
{ lib }:
dir:
let
  all = import ../tests/lib/directories.nix { inherit lib; } dir;
  hasHostFile = hostName: builtins.pathExists (dir + "/${hostName}/host.nix");
  isDarwin =
    hostName: hasHostFile hostName && (import (dir + "/${hostName}/host.nix")).kind or null == "darwin";
in
{
  inherit all;
  nixos = lib.filter (hostName: !hasHostFile hostName) all;
  # Any other kind a host.nix names lands here, so the Linux assembly rejects
  # it by name rather than the host silently disappearing.
  linux = lib.filter (hostName: hasHostFile hostName && !isDarwin hostName) all;
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
