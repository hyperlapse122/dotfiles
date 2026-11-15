{ config, lib, ... }:
{
  services.bootvine.enable = true;

  # Bootstrap keeps the menu available for installation and recovery.
  # systemd-boot opens the production menu when a key is held at power-on.
  boot.loader.timeout = lib.mkIf (!config.my.bootstrap) 0;
}
