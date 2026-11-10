{ config, ... }:
{
  # Every macOS host imports this profile, as every NixOS host imports
  # modules/nixos/profile.nix. Hosts differ only through traits and the
  # values their default.nix sets.
  imports = [
    ./nix.nix
    ./host-marker.nix
    ./defaults.nix
    ./dock.nix
    ./homebrew.nix
    ./fonts.nix
    ./xcode.nix
    ./app-store.nix
    ./retired-casks.nix
    ./tls-inspection-ca.nix
    ./network-recovery.nix
  ];

  # nix-darwin applies user-scoped settings, Homebrew included, for this
  # account, and Home Manager's darwin module needs the account's home.
  system.primaryUser = config.my.user.name;
  users.users.${config.my.user.name}.home = config.my.user.home;

  # Pinned so a nix-darwin update cannot change state-dependent defaults on a
  # host that is already set up.
  system.stateVersion = 7;
}
