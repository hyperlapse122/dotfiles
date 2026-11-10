{ config, lib, ... }:
let
  user = config.system.primaryUser;
  prefix = config.homebrew.prefix;
  brew = "${prefix}/bin/brew";
  retired = [
    "grok-bot"
    "orca"
  ];
  # Taps whose every cask is retired. Taps stay mutable (homebrew.nix), so
  # nothing else removes one the configuration stops naming. The tap list is
  # matched as whole lines in the shell, not through a pipe into grep -q,
  # which can report a miss under pipefail when grep exits early.
  retiredTaps = [ "stablyai/orca" ];
in
{
  # A cask the configuration no longer lists stays installed, because
  # homebrew.onActivation.cleanup is "none"; this step removes the retired
  # ones. It never passes --zap, so the app's user data stays in place: the
  # grok-bot cask declares only `app "Grok Bot.app"` and a `zap trash:` list
  # of ~/Library paths, and no `uninstall` stanza (homebrew-cask
  # Casks/g/grok-bot.rb at 37b48ceb2d85), so uninstall removes the app bundle
  # and Homebrew's own records and nothing under ~/Library. Orca's user data is
  # removed by the retireOrca Home Manager step instead. The orca cask is
  # named by its bare token, the name its Caskroom directory carries, and is
  # uninstalled before its stablyai/orca tap is removed. --force only
  # unpins a pinned cask, tolerates a missing or occupied app path, and purges
  # the cask's Caskroom directory (brew cask/installer.rb, cask/uninstall.rb);
  # it never runs the zap stanza.
  #
  # Homebrew refuses to run as root and `launchctl asuser` leaves the process
  # root, so brew runs through sudo as the primary user the way nix-darwin's
  # own Homebrew activation calls it, with brew's prefix on a PATH sudo
  # preserves. Every command that can fail sits in an `if !` guard and prints
  # one line, so a failed brew never stops the `set -e` activate script.
  #
  # `brew list --cask <token>` exits non-zero with nothing on stderr when the
  # Caskroom has no directory for the token (brew cmd/list.rb), and older
  # releases print "Error: Cask '<token>' is not installed." instead. Only
  # those two results mean the cask is absent; any other failure, such as
  # sudo refusing the call, prints brew's stderr on one line.
  system.activationScripts.postActivation.text = lib.mkOrder 800 ''
    retiredBrew() {
      PATH="${prefix}/bin:$PATH" /usr/bin/sudo --preserve-env=PATH --user=${user} --set-home /usr/bin/env NONINTERACTIVE=1 ${brew} "$@"
    }
    ${lib.concatMapStrings (cask: ''
      if ! retiredList=$(retiredBrew list --cask ${cask} 2>&1 >/dev/null); then
        if [ -z "$retiredList" ] || [ "$retiredList" = "Error: Cask '${cask}' is not installed." ]; then
          echo "retired casks: no ${cask} cask to remove" >&2
        else
          echo "retired casks: could not tell whether ${cask} is installed: ''${retiredList//$'\n'/ }; run brew list --cask ${cask} as ${user}" >&2
        fi
      elif ! retiredBrew uninstall --cask --force ${cask}; then
        echo "retired casks: uninstalling ${cask} failed; run brew uninstall --cask --force ${cask} as ${user}" >&2
      else
        echo "retired casks: removed the ${cask} cask" >&2
      fi
    '') retired}
    ${lib.concatMapStrings (tap: ''
      if ! retiredTaps=$(retiredBrew tap 2>&1); then
        echo "retired taps: could not list taps: ''${retiredTaps//$'\n'/ }; run brew tap as ${user}" >&2
      elif [[ $'\n'"$retiredTaps"$'\n' != *$'\n'${tap}$'\n'* ]]; then
        echo "retired taps: no ${tap} tap to remove" >&2
      elif ! retiredBrew untap ${tap}; then
        echo "retired taps: untapping ${tap} failed; run brew untap ${tap} as ${user}" >&2
      else
        echo "retired taps: removed the ${tap} tap" >&2
      fi
    '') retiredTaps}
  '';
}
