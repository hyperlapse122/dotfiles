# NixOS hosts have no host.nix. A host.nix must declare the Darwin kind.
{ lib }:
dir:
let
  all = import ./directories.nix { inherit lib; } dir;
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

  variantsOf =
    mkHost: hostNames:
    builtins.listToAttrs (
      lib.concatMap (
        hostName:
        map
          (bootstrap: {
            name = if bootstrap then "${hostName}-bootstrap" else hostName;
            value = mkHost {
              inherit hostName bootstrap;
              dir = dir + "/${hostName}";
            };
          })
          [
            false
            true
          ]
      ) hostNames
    );
}
