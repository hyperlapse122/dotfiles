{
  config,
  lib,
  pkgs,
  ...
}:
{
  home.activation.ghosttyDefaultTerminal = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.duti}/bin/duti -s com.mitchellh.ghostty public.unix-executable all
    ''
  );
  programs.ghostty = {
    enable = true;
    # nixpkgs builds Ghostty for Linux only; macOS installs the ghostty cask
    # (modules/shared/darwin-apps.nix), and Home Manager writes the same settings.
    package = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin null;
    settings = {
      # Keep the baseline emoji fallback after the primary text families.
      font-family = [
        "Jetendard"
        "JetBrainsMono Nerd Font"
        "D2CodingLigature Nerd Font"
        "D2KodingLigature Nerd Font"
        "Twitter Color Emoji"
      ];
    };
  };
}
