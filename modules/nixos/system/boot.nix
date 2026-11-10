{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The host exposes this switch so the bootstrap output can import the same
  # hardware and filesystem declarations without enabling Secure Boot.
  bootstrap = config.my.bootstrap or false;
in
{
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-partlabel/disk-main-luks";
    crypttabExtraOpts = lib.mkIf (!bootstrap) [
      "tpm2-device=auto"
      "tpm2-pcrs=7"
    ];
  };

  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.efi.canTouchEfiVariables = lib.mkForce bootstrap;
  boot.loader.systemd-boot.configurationLimit = 5;

  # Lanzaboote's module is imported by the host flake output.  The key bundle
  # is deliberately outside the Nix store and must be provisioned separately.
  boot.loader.systemd-boot.enable = lib.mkForce bootstrap;
  boot.lanzaboote.enable = lib.mkIf (!bootstrap) true;
  boot.lanzaboote.pkiBundle = lib.mkIf (!bootstrap) "/var/lib/sbctl";
  boot.lanzaboote.allowUnsigned = lib.mkIf (!bootstrap) false;
  boot.lanzaboote.configurationLimit = lib.mkIf (!bootstrap) 5;

  fileSystems."/boot".options = [ "umask=0077" ];
}
