# Nix settings every host shares, whether NixOS writes nix.conf or the
# non-NixOS system layer does.
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.auto-optimise-store = true;
  # Declared wholesale rather than via extra-* so the trusted set on both
  # hosts is exactly this list; cache.nixos.org is restated because setting
  # substituters replaces the built-in default.
  nix.settings.substituters = [
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
}
