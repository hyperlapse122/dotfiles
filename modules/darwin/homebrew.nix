{ config, lib, ... }:
let
  inherit (import ../shared/darwin-apps.nix) apps casks tapOf;
  thirdParty = lib.filter (cask: tapOf cask != null) casks;
  enabledCasks = lib.filter (cask: !config.my.bootstrap || cask != apps.ollama.cask) casks;
  caskArgs = {
    ${apps.firefox-developer-edition.cask} = {
      appdir = "/Applications";
      language = "ko";
    };
    ${apps.google-chrome.cask}.appdir = "/Applications";
  };
in
{
  # nix-homebrew launches brew with "nix" as both core update revisions, but
  # Homebrew now requires hexadecimal object IDs before reporting tap updates.
  # brew.env loads after those defaults; equal zero IDs retain no-core-update
  # semantics while satisfying the guard.
  environment.etc."homebrew/brew.env".text = ''
    HOMEBREW_UPDATE_BEFORE=0000000000000000000000000000000000000000
    HOMEBREW_UPDATE_AFTER=0000000000000000000000000000000000000000
  '';

  # nix-homebrew installs Homebrew itself on the first apply, so a new Mac
  # needs only Nix installed by hand. Taps stay mutable: an immutable tap set
  # turns off Homebrew's auto-update for every brew call.
  nix-homebrew = {
    enable = true;
    user = config.system.primaryUser;
    # A Mac that already has Homebrew at /opt/homebrew is taken over in place;
    # without this, the first apply stops on the existing installation.
    autoMigrate = true;
    # Homebrew loads a cask from a non-official tap only once it is trusted.
    trust.casks = thirdParty;
  };

  homebrew = {
    enable = true;
    taps = lib.unique (map tapOf thirdParty);
    casks = map (
      name:
      if caskArgs ? ${name} then
        {
          inherit name;
          args = caskArgs.${name};
        }
      else
        name
    ) enabledCasks;
    brews = [
      "aria2"
      "container"
    ];
    onActivation = {
      # Apps installed outside the list stay installed.
      cleanup = "none";
      # An apply installs missing casks and upgrades outdated ones; apps that
      # update themselves are left to their own updater. Off, autoUpdate
      # passes HOMEBREW_NO_AUTO_UPDATE=1 to brew bundle, and Homebrew then
      # never refreshes its cask metadata, so upgrade would never see a newer
      # version. Homebrew itself stays pinned by nix-homebrew.
      upgrade = true;
      autoUpdate = true;
    };
  };
}
