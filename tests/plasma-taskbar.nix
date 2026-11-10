/*
  Check interface:

    import ./tests/plasma-taskbar.nix { inherit pkgs self; }

  Asserts that the KDE Plasma applets activation script declares the pinned taskbar
  launchers in the specified order (Google Chrome, Dolphin, Ghostty, then
  T3 Code when its desktop app is installed).

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike (home/h82/desktop/kde/plasma.nix is not
  gated on my.bootstrap, so the bootstrap desktop gets the same taskbar), and
  on each production configuration re-evaluated with my.t3.desktop.enable
  forced off:
  - h82's Home Manager generation defines a non-empty kdePlasmaApplets
    activation script.
  - Pinned applications are ordered as: preferred://browser, preferred://filemanager,
    applications:com.mitchellh.ghostty.desktop, followed by
    applications:t3code.desktop exactly when my.t3.desktop.enable is on, so
    no host pins a launcher whose desktop file is not installed.
  - Task grouping stays disabled (groupingStrategy 0).

  Every configuration enables the T3 Code desktop trait today, so the
  forced-off configurations keep the trait-off list from passing untested.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  desktopEnabled = config: config.my.t3.desktop.enable;
  desktopTrait = configurations.withTrait "my.t3.desktop.enable" desktopEnabled;

  expectedLaunchers =
    entry:
    lib.concatStringsSep "," (
      [
        "preferred://browser"
        "preferred://filemanager"
        "applications:com.mitchellh.ghostty.desktop"
      ]
      ++ lib.optional (desktopEnabled entry.config) "applications:t3code.desktop"
    );

  assertEntry =
    entry:
    let
      activationData = entry.user.home.activation.kdePlasmaApplets.data or null;
      scriptFile = pkgs.writeText "${entry.name}-kde-plasma-applets.sh" (
        if activationData != null then activationData else ""
      );
    in
    ''
      ${lib.optionalString
        (!(lib.elem "writeBoundary" (entry.user.home.activation.kdePlasmaApplets.after or [ ])))
        ''
          echo "taskbar activation must run after writeBoundary on ${entry.name}" >&2
          failed=1
        ''
      }
      if [ ! -s "${scriptFile}" ]; then
        echo "kdePlasmaApplets activation script is missing or empty on ${entry.name}" >&2
        failed=1
      else
        export HOME=$(mktemp -d)
        export XDG_CONFIG_HOME="$HOME/.config"
        mkdir -p "$XDG_CONFIG_HOME"
        applets="$XDG_CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc"
        cat > "$applets" <<'APPLET'
      [Containments][2][Applets][3]
      plugin=org.kde.plasma.icontasks
      [Containments][2][Applets][3][Configuration][General]
      launchers=stale
      groupingStrategy=1
      preserved=first
      [Containments][7][Applets][8]
      plugin=org.kde.plasma.taskmanager
      [Containments][7][Applets][8][Configuration][General]
      launchers=stale
      groupingStrategy=2
      preserved=second
      [Containments][7][Applets][9]
      plugin=org.example.unrelated
      [Containments][7][Applets][9][Configuration][General]
      launchers=untouched
      APPLET
        if ! ${pkgs.bash}/bin/bash -eu "${scriptFile}"; then
          echo "taskbar activation failed on ${entry.name}" >&2
          failed=1
        fi
        for pair in 2:3 7:8; do
          containment=''${pair%:*}
          applet=''${pair#*:}
          readGeneral() {
            ${pkgs.kdePackages.kconfig}/bin/kreadconfig6 --file "$applets" \
              --group Containments --group "$containment" --group Applets --group "$applet" \
              --group Configuration --group General --key "$1"
          }
          if [ "$(readGeneral launchers)" != "${expectedLaunchers entry}" ] || [ "$(readGeneral groupingStrategy)" != 0 ]; then
            echo "taskbar activation did not reconcile $pair on ${entry.name}" >&2
            failed=1
          fi
          case "$pair:$(readGeneral preserved)" in
            2:3:first|7:8:second) ;;
            *) echo "taskbar activation lost unrelated data" >&2; failed=1 ;;
          esac
        done
        applet=9
        if [ "$(readGeneral launchers)" != untouched ]; then
          echo "taskbar activation changed an unrelated applet" >&2
          failed=1
        fi
      fi
    '';
in
pkgs.runCommand "plasma-taskbar-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -x
  ${configurations.guard}
  ${desktopTrait.guard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertEntry (configurations.entries ++ desktopTrait.disabled)}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
