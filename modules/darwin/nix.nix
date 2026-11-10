{ lib, ... }:
{
  # nix.conf is the flake's to own, as on NixOS and the non-NixOS Linux hosts,
  # so the upstream multi-user installer's daemon runs with the shared
  # settings. The installer's own /etc/nix/nix.conf is moved aside once before
  # the first apply (docs/macos.md).
  imports = [ ../shared/nix-settings.nix ];
  nix.enable = true;

  # Store auto-optimisation corrupts the store on macOS (NixOS/nix#7273).
  nix.settings.auto-optimise-store = lib.mkForce false;
}
