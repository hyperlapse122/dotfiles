{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; })
    forEveryConfiguration
    assertUserPackage
    ;
  packages = [
    {
      pname = "kleopatra";
      executables = [ "kleopatra" ];
      desktopEntries = [ "org.kde.kleopatra.desktop" ];
    }
    {
      pname = "telegram-desktop";
      executables = [ "Telegram" ];
      desktopEntries = [ "org.telegram.desktop.desktop" ];
    }
    {
      pname = "libreoffice";
      executables = [ "libreoffice" ];
      desktopEntries = [
        "writer.desktop"
        "calc.desktop"
        "impress.desktop"
      ];
    }
    {
      pname = "okular";
      executables = [ "okular" ];
      # okularApplication_pdf.desktop is NoDisplay and only proves PDF handling;
      # org.kde.okular.desktop is the entry the application launcher shows.
      desktopEntries = [
        "org.kde.okular.desktop"
        "okularApplication_pdf.desktop"
      ];
    }
    {
      pname = "discord";
      executables = [ "discord" ];
      desktopEntries = [ "discord.desktop" ];
    }
  ];
in
pkgs.runCommand "desktop-packages-tests" { } ''
  set -x
  ${pkgs.lib.concatMapStrings (spec: forEveryConfiguration (assertUserPackage spec)) packages}
  touch $out
''
