{ pkgs, ... }:
let
  # NixOS does not link a package's etc/ into /etc, so Chrome never finds the
  # native messaging manifest that plasma-browser-integration ships.
  manifest = "${pkgs.kdePackages.plasma-browser-integration}/etc/opt/chrome/native-messaging-hosts/org.kde.plasma.browser_integration.json";
in
{
  home.file.".config/google-chrome/NativeMessagingHosts/org.kde.plasma.browser_integration.json".source =
    manifest;
}
