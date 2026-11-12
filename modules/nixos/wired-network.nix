{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.wiredNetwork;
  inherit (config.my) hostName;
  active = cfg.enable && !config.my.bootstrap;
  tool = lib.getExe (import ../../packages/nixos-wired-network.nix { inherit pkgs; });
  identity = config.my.cliAuth.ageKeyFile;
in
{
  options.my.wiredNetwork.file = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default =
      let
        file = ../../secrets/hosts + "/${hostName}/wired-network.yaml";
      in
      if builtins.pathExists file then file else null;
    description = "Encrypted YAML declaring the wired adapter's `mac`, `ipv4_address`, `ipv4_subnet_mask`, `ipv4_router`, and `dns_servers`, decrypted with the host identity when the profile is rendered.";
  };

  config = lib.mkIf active {
    assertions = [
      {
        assertion = cfg.file != null;
        message = "${hostName}: my.wiredNetwork.enable needs secrets/hosts/${hostName}/wired-network.yaml; see secrets/README.md.";
      }
    ];

    # Runs before NetworkManager so the profile exists when NetworkManager
    # first reads its connection directories; a profile added after the wired
    # device has activated is not applied until it reconnects. It needs only
    # the age identity, not sops-install-secrets, so a bad wired file cannot
    # stop other secrets from installing. A changed file is a new store path,
    # which changes the unit and reruns it on a switch.
    systemd.services.nixos-wired-network = {
      description = "Render the declared wired NetworkManager profile";
      wantedBy = [
        "NetworkManager.service"
        "multi-user.target"
      ];
      before = [ "NetworkManager.service" ];
      after = [ "local-fs.target" ];
      unitConfig.RequiresMountsFor = [ (dirOf identity) ];
      path = [ config.networking.networkmanager.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 30;
        UMask = "0022";
        ExecStart = lib.escapeShellArgs [
          tool
          "--file"
          "${cfg.file}"
          "--identity"
          identity
          "--owner"
          "root"
          "--output-dir"
          "/run/NetworkManager/system-connections"
        ];
      };
    };
  };
}
