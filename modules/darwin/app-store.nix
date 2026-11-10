{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;
  apps = [
    {
      name = "KakaoTalk";
      id = "869223134";
      tag = "kakaotalk";
    }
    {
      name = "Flighty";
      id = "1358823008";
      tag = "flighty";
    }
  ];
  appStep = app: ''
    echo "setting up ${app.name}..." >&2
    if [[ -z $appStoreUid || -z $appStoreGid ]]; then
      echo "${app.tag}: cannot resolve the ids of ${user}; system.primaryUser must name an existing account" >&2
    elif [[ ! -d /Applications/${app.name}.app ]]; then
      # install covers only apps the account already obtained.
      if ! appStoreMas install ${app.id} && ! appStoreMas get ${app.id}; then
        echo "${app.tag}: App Store install failed; sign in to the App Store as ${user} and apply again" >&2
      fi
    elif ! appStoreMas upgrade ${app.id}; then
      echo "${app.tag}: App Store upgrade failed; check that ${user} is signed in to the App Store and that /Applications/${app.name}.app came from the App Store" >&2
    fi
  '';
in
{
  # Mac App Store apps come from mas, for the reasons xcode.nix gives for not
  # using homebrew.masApps or programs.mas, and with the same shape: every mas
  # call runs in the user's session with SUDO_UID set, and every command that
  # can fail sits in an `if !` guard, so a signed-out App Store never stops
  # the `set -e` activate script. Each app in `apps` gets its own
  # install-or-upgrade block.
  #
  # Order 750 runs this after the Xcode step (mkBefore, 500) and before Home
  # Manager's activation call (default, 1000), while still root.
  system.activationScripts.postActivation.text = lib.mkOrder 750 ''
    appStoreUid=$(/usr/bin/id -u ${user} 2>/dev/null) || appStoreUid=
    appStoreGid=$(/usr/bin/id -g ${user} 2>/dev/null) || appStoreGid=
    appStoreMas() {
      /bin/launchctl asuser "$appStoreUid" /usr/bin/env SUDO_UID="$appStoreUid" SUDO_GID="$appStoreGid" ${lib.getExe pkgs.mas} "$@"
    }
    ${lib.concatMapStrings appStep apps}
  '';
}
