{ pkgs, self }:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  checkDesktop =
    entry:
    let
      browser = lib.findFirst (
        p: lib.getName p == "firefox-developer-edition"
      ) null entry.user.home.packages;
      activation = entry.user.home.activation.firefoxDeveloperEdition.data or "";
    in
    if browser == null then
      ''echo "missing Firefox Developer Edition launcher on ${entry.name}" >&2; exit 1''
    else
      ''
        export HOME=$(mktemp -d)
        export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_DIRS="${browser}/share"
        installDir="$HOME/.local/opt/firefox-developer-edition"
        mkdir -p "$XDG_CONFIG_HOME" "$installDir"
        # Stand in for a copy that Firefox has already updated. Its next launch
        # must receive the original link even when activation runs again.
        cat > "$installDir/firefox" <<'BROWSER'
        #!${pkgs.runtimeShell}
        printf '%s\n' "$@" > "$HOME/opened-links"
        BROWSER
        chmod +x "$installDir/firefox"
        cat > "$XDG_CONFIG_HOME/mimeapps.list" <<'MIME'
        [Default Applications]
        x-scheme-handler/http=old-browser.desktop
        x-scheme-handler/https=old-browser.desktop
        text/html=my-editor.desktop
        MIME
        cp "$XDG_CONFIG_HOME/mimeapps.list" "$XDG_CONFIG_HOME/kde-mimeapps.list"
        ${pkgs.runtimeShell} -eu ${pkgs.writeText "activate-browser" activation}
        test "$(kreadconfig6 --file kdeglobals --group General --key BrowserApplication)" = "$desktopId"
        for file in mimeapps.list kde-mimeapps.list; do
          for scheme in http https; do
            handler=$(kreadconfig6 --file "$file" --group 'Default Applications' --key "x-scheme-handler/$scheme")
            test "''${handler%;}" = "$desktopId"
          done
          test "$(kreadconfig6 --file "$file" --group 'Default Applications' --key text/html)" = my-editor.desktop
        done
        desktopFile="${browser}/share/applications/$desktopId"
        desktop-file-validate "$desktopFile"
        gio launch "$desktopFile" "$link"
        timeout 10 ${pkgs.runtimeShell} -c 'until test -s "$HOME/opened-links"; do sleep .05; done'
        test "$(cat "$HOME/opened-links")" = "$link"
      '';
in
pkgs.runCommand "firefox-developer-edition-tests"
  {
    nativeBuildInputs = [
      pkgs.kdePackages.kconfig
      pkgs.desktop-file-utils
      pkgs.glib
    ];
  }
  ''
    ${configurations.guard}
    desktopId=firefox-developer-edition.desktop
    link='https://example.org/a%20b?q=one&next=two#fragment'
    ${lib.concatMapStringsSep "\n" checkDesktop configurations.entries}
    touch "$out"
  ''
