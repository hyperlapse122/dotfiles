{ config, pkgs, ... }:
let
  defaultBrowser = pkgs.runCommandCC "firefox-developer-default-browser" { } ''
    mkdir -p "$out/bin"
    clang -fobjc-arc -framework Cocoa \
      ${../../../scripts/macos-firefox-default.m} -o "$out/bin/firefox-developer-default"
  '';
  provision = pkgs.writeShellScript "firefox-developer-provision" ''
    exec ${pkgs.python3}/bin/python3 ${../../../scripts/macos-firefox-provision.py} \
      ${defaultBrowser}/bin/firefox-developer-default
  '';
in
{
  launchd.agents.firefox-developer = {
    enable = true;
    config = {
      ProgramArguments = [ "${provision}" ];
      LimitLoadToSessionType = "Aqua";
      RunAtLoad = true;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/firefox-developer.log";
    };
  };
}
