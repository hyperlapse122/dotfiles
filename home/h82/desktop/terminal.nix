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
  # Ghostty's unit is Type=notify-reload, but Ghostty sends READY=1 before it
  # installs its SIGUSR2 handler. systemd 262 refuses to start a notify-reload
  # service whose main process has no handler for the reload signal at READY,
  # so the D-Bus-activated service fails with Result=protocol and no window
  # opens. Plain notify plus an explicit ExecReload keeps config reloads
  # (Home Manager's X-Reload-Triggers) working.
  xdg.configFile."systemd/user/app-com.mitchellh.ghostty.service.d/notify.conf" =
    lib.mkIf config.programs.ghostty.systemd.enable
      {
        text = ''
          [Service]
          Type=notify
          ExecReload=${pkgs.coreutils}/bin/kill -USR2 $MAINPID
        '';
      };
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
