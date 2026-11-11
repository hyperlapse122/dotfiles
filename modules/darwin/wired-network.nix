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
  tool = lib.getExe (import ../../packages/macos-wired-network.nix { inherit pkgs; });
in
{
  options.my.wiredNetwork.file = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default =
      let
        file = ../../secrets/hosts + "/${hostName}/wired-network.yaml";
      in
      if builtins.pathExists file then file else null;
    description = "Encrypted YAML declaring the wired adapter's `mac`, `ipv4_address`, `ipv4_subnet_mask`, `ipv4_router`, and `dns_servers`, decrypted with the host identity at activation.";
  };

  config = lib.mkIf active {
    assertions = [
      {
        assertion = cfg.file != null;
        message = "${hostName}: my.wiredNetwork.enable needs secrets/hosts/${hostName}/wired-network.yaml; see docs/macos.md.";
      }
    ];

    # Last, after the Homebrew, Xcode, and container steps, so the brief wired
    # drop a rewrite can cause never interrupts their downloads. The script
    # warns and exits 0 on every failure, so it never aborts the apply.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      echo "checking the wired network settings..." >&2
      ${tool} \
        --file ${lib.escapeShellArg "${cfg.file}"} \
        --identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \
        --owner ${lib.escapeShellArg config.my.user.name}
    '';
  };
}
