{ config, pkgs, ... }:
let
  defaultBrowser = pkgs.runCommandCC "macos-default-browser" { } ''
    mkdir -p "$out/bin"
    clang -fobjc-arc -framework Cocoa \
      ${../../../scripts/macos-default-browser.m} -o "$out/bin/macos-default-browser"
  '';
  selectBrowser = pkgs.writeShellScript "select-google-chrome" ''
    set -e
    # Brew can adopt an existing app. Chrome's signed updater may carry Finder metadata.
    /usr/bin/codesign --verify --deep --strict=symlinks \
      -R '=anchor apple generic and identifier "com.google.Chrome" and certificate leaf[subject.OU] = "EQHXZ8M8AV"' "$1"
    exec ${defaultBrowser}/bin/macos-default-browser "$1"
  '';
in
{
  launchd.agents.google-chrome-default = {
    enable = true;
    config = {
      ProgramArguments = [
        "${selectBrowser}"
        "/Applications/Google Chrome.app"
      ];
      LimitLoadToSessionType = "Aqua";
      RunAtLoad = true;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/google-chrome-default.log";
    };
  };
}
