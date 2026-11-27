{ config, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  my.user.name = "h82";
  my.user.home = "/home/h82";
  my.nuphyGem80.enable = true;
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
