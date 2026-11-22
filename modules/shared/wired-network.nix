{ config, lib }:
let
  cfg = config.my.wiredNetwork;
  inherit (config.my) hostName;
  active = cfg.enable && !config.my.bootstrap;
  guide = if config.my.kind == "darwin" then "docs/macos.md" else "secrets/README.md";
in
{
  inherit active;
  module = {
    options.my.wiredNetwork.file = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = import ../../lib/host-secret-file.nix hostName "wired-network.yaml";
      description = "Encrypted YAML declaring the wired adapter's `mac`, `ipv4_address`, `ipv4_subnet_mask`, `ipv4_router`, and `dns_servers`, decrypted with the host identity.";
    };

    config = lib.mkIf active {
      assertions = [
        {
          assertion = cfg.file != null;
          message = "${hostName}: my.wiredNetwork.enable needs secrets/hosts/${hostName}/wired-network.yaml; see ${guide}.";
        }
      ];
    };
  };
}
