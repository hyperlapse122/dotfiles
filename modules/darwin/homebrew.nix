{ config, lib, ... }:
let
  inherit (import ../shared/darwin-apps.nix) casks tapOf;
  thirdParty = lib.filter (cask: tapOf cask != null) casks;
in
{
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
    inherit casks;
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
