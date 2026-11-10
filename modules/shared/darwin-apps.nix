/*
  The macOS decision for every package a NixOS host's user environment has and
  a non-NixOS Linux host's lacks, keyed by package name: the GUI apps, plus the
  desktop and trait packages that come with them. The darwin-config check
  derives that set from evaluated configurations and fails on any name missing
  here, so adding an app on NixOS forces a macOS decision. `apps` also maps a
  package every Linux host has that a Mac gets as a cask; the derived set
  cannot cover it, so the check pins it by value.

  Each entry is one of
    { cask = "<Homebrew cask>"; }   installed from Homebrew on macOS
    { nix = "<where>"; }            installed from Nix on macOS, by that module
    { leftOut = "<reason>"; }       not installed on macOS

  `darwinOnly` lists casks macOS hosts install with no NixOS counterpart, and
  `casks` is every cask a macOS host installs. `tapOf` names the tap of a
  third-party cask, `<owner>/<tap>/<cask>`, and is null for a core cask.
*/
let
  apps = {
    "1password".cask = "1password";
    chatgpt.cask = "chatgpt";
    claude-desktop.cask = "claude";
    discord.cask = "discord";
    ghostty.cask = "ghostty";
    google-chrome.cask = "google-chrome";
    libreoffice.cask = "libreoffice";
    telegram-desktop.cask = "telegram-desktop";
    wifiman-desktop.cask = "wifiman";
    yubioath-flutter.cask = "yubico-authenticator";

    code.nix = "home/h82/dev/vscodium.nix";
    nixd.nix = "home/h82/dev/vscodium.nix";
    vscodium.nix = "home/h82/dev/vscodium.nix";
    t3code-cli.nix = "home/h82/t3code.nix, the my.t3.cli trait";
    t3code-desktop.nix = "home/h82/t3code.nix, the my.t3.desktop trait, from the nightly pin";

    kleopatra.leftOut = "a KDE GnuPG front end; gpg on the command line covers macOS";
    ksshaskpass.leftOut = "the KDE askpass; macOS has no KDE session";
    okular.leftOut = "a KDE document viewer; macOS has Preview";
    configure-kde-input-devices.leftOut = "configures KDE input devices; macOS has no KDE";
    desktop-ssh.leftOut = "the NixOS desktop SSH agent; a macOS host uses its own host key";
    dummy-fc-dir1.leftOut = "a fontconfig directory placeholder; macOS fonts go through CoreText";
    dummy-fc-dir2.leftOut = "a fontconfig directory placeholder; macOS fonts go through CoreText";
    nr.leftOut = "the NixOS apply helper; macOS gets nr-darwin";
  };

  darwinOnly = [
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
