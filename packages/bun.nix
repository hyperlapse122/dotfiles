{ pkgs }:
let
  pin = builtins.fromJSON (builtins.readFile ./bun-pin.json);
  target =
    {
      x86_64-linux = "linux-amd64";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
    }
    .${pkgs.stdenv.hostPlatform.system};
  asset = pin.targets.${target};
in
pkgs.bun.overrideAttrs {
  version = pkgs.lib.removePrefix "bun-v" pin.tag;
  src = pkgs.fetchurl { inherit (asset) url sha256; };
}
