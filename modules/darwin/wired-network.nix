{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.wiredNetwork;
  shared = import ../shared/wired-network.nix { inherit config lib; };
  tool = lib.getExe (import ../../packages/macos-wired-network.nix { inherit pkgs; });
in
{
  imports = [ shared.module ];

  config = lib.mkIf shared.active {
    # Last, after the Homebrew, Xcode, and container steps, so the brief wired
    # drop a rewrite can cause never interrupts their downloads. No echo here:
    # an unplugged or already matching adapter must leave the switch silent.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      ${tool} \
        --file ${lib.escapeShellArg "${cfg.file}"} \
        --identity ${lib.escapeShellArg "${config.my.user.home}/.config/nix-config/age/key.txt"} \
        --owner ${lib.escapeShellArg config.my.user.name}
    '';
  };
}
