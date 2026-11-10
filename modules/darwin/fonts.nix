{ pkgs, ... }:
{
  # The NixOS font set, installed under /Library/Fonts/Nix Fonts. macOS draws
  # through CoreText, so the NixOS fontconfig fallback order has no
  # counterpart; Ghostty names its fallback families itself.
  fonts.packages = import ../shared/font-packages.nix pkgs;
}
