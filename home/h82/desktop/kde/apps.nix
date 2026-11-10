{
  pkgs,
  lib,
  config,
  ...
}:
let
  kwrite = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
  homeDir = config.home.homeDirectory;
in
{
  home.activation.kdeApps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${kwrite}" ]; then
      # dolphinrc: open home folder on startup without restoring tabs
      ${kwrite} --file dolphinrc --group General --key RememberOpenedTabs --type bool false
      ${kwrite} --file dolphinrc --group General --key HomeUrl "${homeDir}"

      # krunnerrc: terminate applications runner
      ${kwrite} --file krunnerrc --group Runners/krunner_kill --key useTriggerWord --type bool true
      ${kwrite} --file krunnerrc --group Runners/krunner_kill --key triggerWord kill
      ${kwrite} --file krunnerrc --group Runners/krunner_kill --key sorting 1

      # krunnerrc: Spotlight-like search box
      ${kwrite} --file krunnerrc --group General --key FreeFloating --type bool true
      ${kwrite} --file krunnerrc --group General --key historyBehavior ImmediateCompletion

      # spectaclerc: never reuse the last rectangular selection
      ${kwrite} --file spectaclerc --group General --key rememberSelectionRect Never

      # kdeglobals: default terminal application
      ${kwrite} --file kdeglobals --group General --key TerminalApplication ghostty
    fi
  '';
}
