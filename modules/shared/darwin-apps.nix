# darwin-config checks packages present on NixOS against the macOS fixtures.
# Each entry names a Homebrew cask, its Nix module, or the reason for omission.
let
  apps = {
    "1password".cask = "1password";
    chatgpt.cask = "chatgpt";
    claude-desktop.cask = "claude";
    discord.cask = "discord";
    ghostty.cask = "ghostty";
    google-chrome.cask = "google-chrome";
    libreoffice.cask = "libreoffice";
    ollama.cask = "ollama-app";
    telegram-desktop.cask = "telegram-desktop";
    yubioath-flutter.cask = "yubico-authenticator";

    code.nix = "home/h82/dev/vscodium.nix";
    nixd.nix = "home/h82/dev/vscodium.nix";
    vscodium.nix = "home/h82/dev/vscodium.nix";
    t3code-cli.nix = "home/h82/t3code.nix, the my.t3.cli trait";
    t3code-desktop.nix = "home/h82/t3code.nix, the my.t3.desktop trait, from the stable pin";

    kleopatra.leftOut = "a KDE GnuPG front end; gpg on the command line covers macOS";
    ksshaskpass.leftOut = "the KDE askpass; macOS has no KDE session";
    okular.leftOut = "a KDE document viewer; macOS has Preview";
    configure-kde-input-devices.leftOut = "configures KDE input devices; macOS has no KDE";
    desktop-ssh.leftOut = "the NixOS desktop SSH agent; a macOS host uses its own host key";
    dummy-fc-dir1.leftOut = "a fontconfig directory placeholder; macOS fonts go through CoreText";
    dummy-fc-dir2.leftOut = "a fontconfig directory placeholder; macOS fonts go through CoreText";
    wl-clipboard.leftOut = "Wayland clipboard tools; macOS supplies pbcopy and pbpaste";
    shared-mime-info.leftOut = "Linux MIME database; macOS supplies its own type database";
    dummy-xdg-mime-dirs1.leftOut = "Linux MIME directory placeholder";
    dummy-xdg-mime-dirs2.leftOut = "Linux MIME directory placeholder";
    man-db.leftOut = "Linux man page index; macOS supplies man";
    openjdk.leftOut = "macOS gets Java through home/h82/dev/android.nix under its platform-specific package name";
    nr.leftOut = "the NixOS apply helper; macOS gets nr-darwin";
    microsoft-edge.leftOut = "installed on NixOS for Intune enrollment; ABM and Intune manage the Mac's applications";
  };

  darwinOnly = [
    "google-drive"
    "parallels"
    "tailscale-app"
  ];

  tapOf =
    cask:
    let
      parts = builtins.split "/" cask;
    in
    if builtins.length parts == 5 then
      "${builtins.elemAt parts 0}/${builtins.elemAt parts 2}"
    else
      null;
in
{
  inherit apps darwinOnly tapOf;
  casks =
    builtins.concatMap (name: if apps.${name} ? cask then [ apps.${name}.cask ] else [ ]) (
      builtins.attrNames apps
    )
    ++ darwinOnly;
}
