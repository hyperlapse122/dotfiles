{ config, lib, ... }:
{
  # A VMware Workstation guest on the MS-7D91 PC, which runs Windows.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  virtualisation.vmware.guest.enable = true;
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "xhci_pci"
    "sd_mod"
    "sr_mod"
  ];
  hardware.graphics.enable = true;
  services.fstrim.enable = true;
  zramSwap.enable = false;

  # vmwgfx is the virtual GPU's KMS driver; boot-splash.nix needs one in the
  # production initrd.
  boot.initrd.kernelModules = lib.mkIf (!config.my.bootstrap) [ "vmwgfx" ];
}
