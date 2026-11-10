{ config, lib, ... }:
let
  inherit (config.my.user) home;
  homeManagerApps = "${home}/Applications/Home Manager Apps";
in
{
  options.my.dock.hostApps = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "/Applications/Microsoft Outlook.app" ];
    description = "App bundle paths this host pins to the Dock between ChatGPT and Discord, for apps only this host installs.";
  };

  # The declared Dock replaces the pinned apps and right-side items on every
  # apply. Keys left null here, such as position, auto-hide, magnification,
  # and the minimize settings, are never written and stay the user's.
  config.system.defaults.dock = {
    persistent-apps = [
      "/Applications/Google Chrome.app"
      "/System/Applications/Mail.app"
      "/System/Applications/Messages.app"
      "/System/Applications/Phone.app"
      "/System/Applications/FaceTime.app"
      "/System/Applications/iPhone Mirroring.app"
      "/System/Applications/Calendar.app"
      "/System/Applications/Reminders.app"
      "/System/Applications/Notes.app"
      "/System/Applications/Photos.app"
      "/Applications/Ghostty.app"
    ]
    ++ lib.optional config.my.t3.desktop.enable "${homeManagerApps}/T3 Code (Nightly).app"
    ++ [
      "${homeManagerApps}/VSCodium.app"
      "/Applications/Xcode.app"
      "/Applications/Claude.app"
      "/Applications/ChatGPT.app"
    ]
    ++ config.my.dock.hostApps
    ++ [
      "/Applications/Discord.app"
      "/Applications/1Password.app"
      "/System/Applications/System Settings.app"
    ];
    persistent-others = [
      {
        folder = {
          path = "${home}/Downloads";
          arrangement = "date-added";
          displayas = "stack";
          showas = "fan";
        };
      }
    ];
    show-recents = false;
    tilesize = 32;
  };
}
