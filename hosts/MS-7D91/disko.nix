{
  disko.devices.disk.main = {
    type = "disk";
    # This is the only supported installation target. Daily rebuilds never
    # invoke disko's format or destroy actions.
    device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0WB26038A";
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
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            extraFormatArgs = [
              "--type"
              "luks2"
            ];
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
                  mountOptions = [
                    "noatime"
                  ];
                  swap = {
                    swapfile = {
                      size = "64G";
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
