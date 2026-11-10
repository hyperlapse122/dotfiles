{ pkgs, lib, ... }:
let
  kwrite = "${pkgs.kdePackages.kconfig}/bin/kwriteconfig6";
in
{
  # Plasma picks Breeze or Breeze Dark by time of day: startplasma applies the
  # scheduled package at login, and the lookandfeelautoswitcher kded module
  # switches during the session. The activation writes AutomaticLookAndFeel
  # true, overriding a user value that turned it off.
  # Login writes the package's ColorScheme and icon theme to
  # ~/.config/kdedefaults, which a user-file entry outranks, and re-applies
  # colors only when ColorSchemeHash no longer matches the scheme. Deleting
  # those user entries lets the next login apply the scheduled theme in full.
  # The deletes run with no system config dirs: KConfig records a deleted key
  # that has a cascaded default as Key[$d], which would mask kdedefaults too,
  # and erases the key only when no default exists.
  # This runs only when the Home Manager generation changes, not on every
  # rebuild.
  home.activation.kdeTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -x "${kwrite}" ]; then
      ${kwrite} --file kdeglobals --group KDE --key AutomaticLookAndFeel --type bool true
      ${kwrite} --file kdeglobals --group KDE --key DefaultLightLookAndFeel org.kde.breeze.desktop
      ${kwrite} --file kdeglobals --group KDE --key DefaultDarkLookAndFeel org.kde.breezedark.desktop

      XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group General --key ColorScheme --delete
      XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group General --key ColorSchemeHash --delete
      XDG_CONFIG_DIRS=/var/empty ${kwrite} --file kdeglobals --group Icons --key Theme --delete
    fi
  '';
}
