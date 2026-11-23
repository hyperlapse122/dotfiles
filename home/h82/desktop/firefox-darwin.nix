{ config, pkgs, ... }:
let
  defaultBrowser = pkgs.runCommandCC "firefox-developer-default-browser" { } ''
    mkdir -p "$out/bin"
    clang -fobjc-arc -framework Cocoa \
      ${../../../scripts/macos-firefox-default.m} -o "$out/bin/firefox-developer-default"
  '';
  selectBrowser = pkgs.writeShellScript "select-firefox-developer" ''
    set -e
    # Brew Bundle can adopt an existing app at the cask's destination.
    /usr/bin/codesign --verify --deep --strict \
      -R '=anchor apple generic and identifier "org.mozilla.firefoxdeveloperedition" and certificate leaf[subject.OU] = "43AQ936H96"' "$1"
    exec ${defaultBrowser}/bin/firefox-developer-default "$1"
  '';
in
{
  launchd.agents.firefox-developer = {
    enable = true;
    config = {
      ProgramArguments = [
        "${selectBrowser}"
        "/Applications/Firefox Developer Edition.app"
      ];
      LimitLoadToSessionType = "Aqua";
      RunAtLoad = true;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/firefox-developer.log";
    };
  };
}
