{ config, lib, ... }:
{
  # Every host imports this profile. Hardware-specific modules are imported
  # here too and stay inert until the host enables their trait, so every trait
  # option exists on every configuration.
  imports = [
    ./system/base.nix
    ./system/boot.nix
    ./system/boot-splash.nix
    ./desktop/desktop.nix
    ./desktop/user-avatar.nix
    ./desktop/winbox.nix
    ./desktop/fonts.nix
    ./system/nix-cleanup.nix
    ./system/nix-ld.nix
    ./system/agent-browser-deps.nix
    ./system/omp.nix
    ./services/podman.nix
    ./services/minikube.nix
    ./services/printing.nix
    ./services/tailscale.nix
    ./services/proton-vpn.nix
    ./services/resolved.nix
    ./services/wifiman.nix
    ./services/ssh-server.nix
    ./system/secrets.nix
    ./system/desktop-ssh.nix
    ./wifi.nix
    ./hardware/yubikey.nix
    ../shared/host.nix
  ];

  config.my = {
    podman.enable = lib.mkDefault true;
    # The first cluster start pulls images, so an installer console gets none.
    minikube.enable = lib.mkDefault (config.my.podman.enable && !config.my.bootstrap);
    printing.enable = lib.mkDefault true;
    cliAuth.enable = lib.mkDefault (!config.my.bootstrap);
    cliAuth.enableTokscaleToken = lib.mkDefault true;
    cliAuth.enableSyntheticApiKey = lib.mkDefault true;
    cliAuth.enableExaApiKey = lib.mkDefault true;
    cliAuth.enableOpenRouterApiKey = lib.mkDefault true;
    tailscale.enable = lib.mkDefault (!config.my.bootstrap);
    protonVpn.enable = lib.mkDefault (!config.my.bootstrap);
    wifiman.enable = lib.mkDefault true;
  };
}
