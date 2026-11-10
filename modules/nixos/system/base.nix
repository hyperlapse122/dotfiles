{ config, pkgs, ... }:
{
  imports = [ ../../shared/nix-settings.nix ];

  nixpkgs.config.allowUnfree = true;
  networking.networkmanager.enable = true;
  time.timeZone = "Asia/Seoul";
  i18n.defaultLocale = "ko_KR.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ko_KR.UTF-8";
    LC_IDENTIFICATION = "ko_KR.UTF-8";
    LC_MEASUREMENT = "ko_KR.UTF-8";
    LC_MONETARY = "ko_KR.UTF-8";
    LC_NAME = "ko_KR.UTF-8";
    LC_NUMERIC = "ko_KR.UTF-8";
    LC_PAPER = "ko_KR.UTF-8";
    LC_TELEPHONE = "ko_KR.UTF-8";
    LC_TIME = "ko_KR.UTF-8";
  };
  i18n.supportedLocales = [
    "ko_KR.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
    "C.UTF-8/UTF-8"
  ];
  environment.variables.LANGUAGE = "ko_KR:ko:en_US:en";
  users.users.h82 = {
    isNormalUser = true;
    description = "Joosung Park";
    extraGroups = [
      "wheel"
      "networkmanager"
      "kvm"
    ];
    shell = pkgs.zsh;
  };
  boot.kernelModules = [ "vhost_vsock" ];
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    # Matches the nixpkgs default; the legacy dotfiles' 8192 targeted a stock
    # kernel's 128 and would lower the limit here.
    "fs.inotify.max_user_instances" = 524288;
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.core.wmem_default" = 4194304;
    "net.core.wmem_max" = 4194304;
  };
  programs.zsh.enable = true;
  services.pcscd.enable = true;
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c52b|c548", ATTR{power/wakeup}="disabled"
  '';
  environment.systemPackages =
    with pkgs;
    [
      git
      age
      sops
      gnupg
      dmidecode
      e2fsprogs
    ]
    ++ [ (import ../../../packages/gpg-tools.nix { inherit pkgs; }).restoreAgeIdentity ];

  # A host's production and bootstrap outputs share networking.hostName, so the
  # rebuild helper needs another signal to tell the two generations apart.
  environment.etc."nixos-host-variant".text =
    if config.my.bootstrap then "bootstrap\n" else "production\n";

  system.stateVersion = "26.05";
}
