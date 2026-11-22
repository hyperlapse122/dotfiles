{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; }) forEveryConfiguration;
  assertConfiguration =
    entry:
    let
      ghosttyConfig =
        if entry.user ? home-files then "${entry.user.home-files}/.config/ghostty/config" else null;
      monospaceFonts = builtins.toJSON entry.config.fonts.fontconfig.defaultFonts.monospace;
    in
    ''
      ${pkgs.lib.optionalString (ghosttyConfig == null) ''
        echo 'missing xdg.configFile ghostty/config on ${entry.name}' >&2
        fail=1
      ''}
      ${pkgs.lib.optionalString (ghosttyConfig != null) (
        pkgs.lib.concatMapStrings
          (font: ''
            if [ ! -f ${pkgs.lib.escapeShellArg ghosttyConfig} ] || ! grep -Fxq "font-family = ${font}" ${pkgs.lib.escapeShellArg ghosttyConfig}; then
              echo 'ghostty config does not set font-family = ${font} on ${entry.name}' >&2
              fail=1
            fi
          '')
          [
            "Jetendard"
            "JetBrainsMono Nerd Font"
            "D2CodingLigature Nerd Font"
            "D2KodingLigature Nerd Font"
            "Twitter Color Emoji"
          ]
      )}
      ${pkgs.lib.optionalString (ghosttyConfig != null) ''
        # Twemoji covers ASCII digits and space, so it must stay
        # after every text font.
        if [ "$(grep '^font-family = ' ${ghosttyConfig} | tail -n 1)" != 'font-family = Twitter Color Emoji' ] \
          || [ "$(grep -cFx 'font-family = Twitter Color Emoji' ${ghosttyConfig})" -ne 1 ]; then
          echo 'ghostty config does not list Twitter Color Emoji once, last, on ${entry.name}' >&2
          fail=1
        fi
      ''}
      ${pkgs.lib.concatMapStrings
        (font: ''
          if ! echo '${monospaceFonts}' | grep -q "${font}"; then
            echo 'default monospace fonts do not include ${font} on ${entry.name}' >&2
            fail=1
          fi
        '')
        [
          "D2CodingLigature Nerd Font"
          "D2KodingLigature Nerd Font"
        ]
      }
    '';
in
pkgs.runCommand "ghostty-font-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  ${forEveryConfiguration assertConfiguration}
  touch $out
''
