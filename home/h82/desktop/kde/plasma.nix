{
  config,
  pkgs,
  lib,
  ...
}:
let
  kwrite = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
  kread = "${pkgs.kdePackages.kconfig}/bin/kreadconfig6";
  # t3code.desktop is installed only with the T3 Code desktop trait
  # (home/h82/t3code.nix), so it is pinned only then.
  pinnedLaunchers = lib.concatStringsSep "," (
    [
      "preferred://browser"
      "preferred://filemanager"
      "applications:com.mitchellh.ghostty.desktop"
    ]
    ++ lib.optional config.my.t3.desktop.enable "applications:t3code.desktop"
  );
in
{
  home.activation.kdePlasmaApplets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${kwrite}" ] && [ -x "${kread}" ]; then
      applet_file="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
      if [ -f "$applet_file" ]; then
        while IFS=':' read -r containment applet; do
          plugin="$(${kread} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --key plugin 2>/dev/null || true)"
          case "$plugin" in
            org.kde.plasma.icontasks|org.kde.plasma.taskmanager)
              # Do not group applications on task manager panel
              ${kwrite} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --group Configuration --group General --key groupingStrategy 0
              # Pinned application launchers
              ${kwrite} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --group Configuration --group General --key launchers "${pinnedLaunchers}"
              ;;
            org.kde.plasma.kickoff)
              # Kickoff launcher: display favorites and applications in list view
              ${kwrite} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --group Configuration --group General --key favoritesDisplay 1
              ${kwrite} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --group Configuration --group General --key applicationsDisplay 1
              ;;
            org.kde.plasma.digitalclock)
              # Digital clock: long date format
              ${kwrite} --file "$applet_file" --group Containments --group "$containment" --group Applets --group "$applet" --group Configuration --group Appearance --key dateFormat longDate
              ;;
          esac
        done < <(${pkgs.gnugrep}/bin/grep -oE '^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$' "$applet_file" | ${pkgs.gnused}/bin/sed -E 's/^\[Containments\]\[([0-9]+)\]\[Applets\]\[([0-9]+)\]$/\1:\2/')
      fi
    fi
  '';
}
