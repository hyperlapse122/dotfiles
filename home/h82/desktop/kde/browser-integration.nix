{ lib, pkgs, ... }:
let
  # NixOS does not link a package's etc/ into /etc, so Chrome never finds the
  # native messaging manifest that plasma-browser-integration ships.
  manifest = "${pkgs.kdePackages.plasma-browser-integration}/etc/opt/chrome/native-messaging-hosts/org.kde.plasma.browser_integration.json";
in
{
  home.file.".config/google-chrome/NativeMessagingHosts/org.kde.plasma.browser_integration.json".source =
    manifest;

  home.activation.defaultBrowser = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kdeglobals --group General \
        --key BrowserApplication google-chrome.desktop
      for mime in x-scheme-handler/http x-scheme-handler/https; do
        ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --file kde-mimeapps.list \
          --group "Default Applications" --key "$mime" google-chrome.desktop
        XDG_CURRENT_DESKTOP=X-Generic ${pkgs.xdg-utils}/bin/xdg-mime default google-chrome.desktop "$mime"
      done
    fi
  '';
}
