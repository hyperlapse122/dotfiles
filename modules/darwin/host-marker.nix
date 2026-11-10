{ config, ... }:
{
  # Read by the macOS `nr` to learn which host and variant it applies,
  # instead of guessing the host from the machine name.
  environment.etc."nix-config-host".text = ''
    host=${config.my.hostName}
    variant=${if config.my.bootstrap then "bootstrap" else "production"}
  '';
}
