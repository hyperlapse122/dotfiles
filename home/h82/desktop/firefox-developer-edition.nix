{
  config,
  lib,
  pkgs,
  ...
}:
let
  libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glib
    nss
    nspr
    dbus
    gtk3
    pango
    cairo
    atk
    at-spi2-core
    gdk-pixbuf
    libx11
    libxext
    libxcomposite
    libxdamage
    libxfixes
    libxrandr
    libxcb
    libxrender
    libxft
    libxinerama
    libxcursor
    libxi
    libxt
    libsm
    libice
    libxkbcommon
    fontconfig
    freetype
    alsa-lib
    libpulseaudio
    libgbm
    libglvnd
    mesa
    udev
    libva
    libnotify
    libdbusmenu-gtk3
    libxscrnsaver
    cups.lib
    pciutils
    vulkan-loader
    ffmpeg
    libsecret
  ];
  libraryPath = lib.makeLibraryPath libraries;
  launcher = pkgs.writeShellApplication {
    name = "firefox-developer-edition";
    runtimeInputs = with pkgs; [
      curl
      python3
      coreutils
    ];
    text = ''
      export LD_LIBRARY_PATH=${lib.escapeShellArg libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
      export NIX_LD_LIBRARY_PATH=${lib.escapeShellArg libraryPath}''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}
      export MOZ_APP_LAUNCHER=${config.home.profileDirectory}/bin/firefox-developer-edition
      exec ${pkgs.runtimeShell} ${../../../scripts/firefox-developer-edition-linux} "$@"
    '';
  };
  desktop = pkgs.makeDesktopItem {
    name = "firefox-developer-edition";
    desktopName = "Firefox Developer Edition";
    genericName = "Web Browser";
    exec = "${launcher}/bin/firefox-developer-edition %U";
    icon = "web-browser";
    categories = [
      "Network"
      "WebBrowser"
    ];
    mimeTypes = [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ];
    startupNotify = true;
    startupWMClass = "firefox-aurora";
  };
in
{
  home.packages = [
    (pkgs.symlinkJoin {
      name = "firefox-developer-edition";
      paths = [
        launcher
        desktop
      ];
    })
  ];
}
