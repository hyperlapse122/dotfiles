{ config, lib, ... }:
{
  services.bootvine.enable = true;

  # systemd-boot opens the production menu when a key is held at power-on.
  boot.loader.timeout = lib.mkIf (!config.my.bootstrap) 0;
}
