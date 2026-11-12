{ config, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  # Enrollment needs a work account, which an installation console never has.
  my.intune.enable = !config.my.bootstrap;
  my.nuphyGem80.enable = true;
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
  my.printing.queues = [ "office" ];
  my.tailscale.advertiseRoutes = !config.my.bootstrap;
  my.wiredNetwork.enable = true;
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-id/ata-ST2000DM008-2UB102_ZK30PHAD-part1";
    fsType = "exfat";
    options = [
      "nofail"
      "uid=1000"
      "gid=100"
      "dmask=0022"
      "fmask=0133"
    ];
  };
}
