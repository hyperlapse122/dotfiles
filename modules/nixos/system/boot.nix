{ pkgs, ... }:
{
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The root filesystem sits unencrypted on the disk: the only NixOS host is a
  # VMware guest whose virtual disk the host protects with BitLocker or VMware
  # encryption, and VMware firmware leaves no practical way to enroll custom
  # Secure Boot keys. Production and bootstrap outputs boot the same way.
  boot.loader.efi.efiSysMountPoint = "/boot";
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;

  fileSystems."/boot".options = [ "umask=0077" ];
}
