{
  disko.devices.disk.main = {
    type = "disk";
    # VMware's virtual NVMe disk. This is the only supported installation
    # target. Daily rebuilds never invoke disko's format or destroy actions.
    device = "/dev/disk/by-id/nvme-VMware_Virtual_NVMe_Disk_VMware_NVME_0000";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "2G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "/root" = {
                mountpoint = "/";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "/home" = {
                mountpoint = "/home";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "/nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "/log" = {
                mountpoint = "/var/log";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
              "/swap" = {
                mountpoint = "/swap";
                mountOptions = [ "noatime" ];
                swap.swapfile.size = "8G";
              };
            };
          };
        };
      };
    };
  };
}
