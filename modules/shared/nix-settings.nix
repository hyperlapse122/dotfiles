# Nix settings every host shares, whether NixOS writes nix.conf or the
# non-NixOS system layer does.
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.auto-optimise-store = true;
}
