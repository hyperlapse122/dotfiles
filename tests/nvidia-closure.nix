{ pkgs, self }:
let
  inherit (pkgs) lib;
  entries = lib.filter (
    entry: lib.elem "nvidia" entry.config.services.xserver.videoDrivers && !entry.bootstrap
  ) (import ./lib/configurations.nix { inherit pkgs self; }).entries;
in
pkgs.runCommand "nvidia-closure"
  { roots = map (entry: entry.config.system.build.toplevel) entries; }
  ''
    test ${toString (builtins.length entries)} -gt 0
    ${lib.concatMapStrings (
      entry:
      let
        closure = pkgs.closureInfo { rootPaths = [ entry.config.system.build.toplevel ]; };
        pathClosure = pkgs.closureInfo { rootPaths = [ entry.config.system.path ]; };
        driver = entry.config.hardware.nvidia.package;
      in
      ''
        grep -Fx '${driver}' ${closure}/store-paths
        if grep -E '/[^/]*cudatoolkit[^/]*$' ${pathClosure}/store-paths; then
          echo 'system path includes cudatoolkit' >&2
          exit 1
        fi
        test '${if entry.config.hardware.nvidia.open then "open" else "proprietary"}' = proprietary
      ''
    ) entries}
    touch $out
  ''
