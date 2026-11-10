{ lib, pkgs, ... }:
{
  programs.ghostty = {
    enable = true;
    # nixpkgs builds Ghostty for Linux only; macOS installs the ghostty cask
    # (modules/shared/darwin-apps.nix), and Home Manager writes the same settings.
    package = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin null;
    settings = {
      # Ghostty picks emoji from this list before fontconfig, and falls back to
      # Noto Color Emoji rather than the fontconfig emoji alias, so Twemoji
      # has to be listed here. It comes last so ASCII stays in JetBrainsMono.
      font-family = [
        "JetBrainsMono Nerd Font"
        "D2CodingLigature Nerd Font"
        "D2KodingLigature Nerd Font"
        "Twitter Color Emoji"
      ];
    };
  };
}
