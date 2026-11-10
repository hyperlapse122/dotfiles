{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;
  xcodeId = "497799835";
in
{
  # Xcode comes from the Mac App Store through mas, called here rather than
  # through homebrew.masApps or programs.mas: brew bundle runs mas as the
  # user, but mas 7 needs root to install, and a failed bundle aborts the
  # activate script; programs.mas exits the whole script when the App Store
  # is signed out. mkBefore places this after Homebrew and before Home
  # Manager, the last point that still runs as root.
  #
  # The activate script runs under `env -i` and `set -e`. mas drops to
  # SUDO_UID for App Store calls, which env -i removes, so each call sets it
  # and runs in the user's session. Every command that can fail sits in an
  # `if !` guard and prints one line, so a signed-out App Store or a failed
  # download never stops the apply.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    echo "setting up Xcode..." >&2
    xcodeApp=/Applications/Xcode.app
    xcodeUid=$(/usr/bin/id -u ${user} 2>/dev/null) || xcodeUid=
    xcodeGid=$(/usr/bin/id -g ${user} 2>/dev/null) || xcodeGid=
    xcodeMas() {
      /bin/launchctl asuser "$xcodeUid" /usr/bin/env SUDO_UID="$xcodeUid" SUDO_GID="$xcodeGid" ${lib.getExe pkgs.mas} "$@"
    }
    if [[ -z $xcodeUid || -z $xcodeGid ]]; then
      echo "xcode: cannot resolve the ids of ${user}; skipping the App Store install" >&2
    elif [[ ! -d $xcodeApp ]]; then
      # install covers only apps the account already obtained.
      if ! xcodeMas install ${xcodeId} && ! xcodeMas get ${xcodeId}; then
        echo "xcode: App Store install failed; sign in to the App Store as ${user} and apply again" >&2
      fi
    elif ! xcodeMas upgrade ${xcodeId}; then
      echo "xcode: App Store upgrade failed; check that ${user} is signed in to the App Store" >&2
    fi

    if [[ -d $xcodeApp ]]; then
      xcodeDeveloper=$(/usr/bin/xcode-select -p 2>/dev/null) || xcodeDeveloper=
      # Leave a developer directory the user picked, such as a beta Xcode.
      if [[ -z $xcodeDeveloper || $xcodeDeveloper == /Library/Developer/CommandLineTools ]]; then
        if ! /usr/bin/xcode-select -s "$xcodeApp/Contents/Developer"; then
          echo "xcode: xcode-select could not switch to $xcodeApp" >&2
        fi
      fi
      if ! /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
        if ! /usr/bin/xcodebuild -license accept; then
          echo "xcode: accepting the Xcode license failed" >&2
        fi
      fi
      if ! /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        if ! /usr/bin/xcodebuild -runFirstLaunch; then
          echo "xcode: Xcode first-launch setup failed" >&2
        fi
      fi
    fi
  '';
}
