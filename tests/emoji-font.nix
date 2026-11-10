/*
  Check interface:

    import ./tests/emoji-font.nix { inherit pkgs self; }

  Asserts that emoji resolve to the color Twemoji font on every configuration
  `tests/lib/configurations.nix` yields, production and bootstrap alike.

  It runs fontconfig against each configuration's built /etc/fonts, not the
  `fonts.fontconfig.defaultFonts` options, so the order nixpkgs merges into
  the generic aliases is what gets tested. fonts.conf includes the absolute
  /etc/fonts/conf.d, which does not exist in the build sandbox, so the check
  loads a copy whose include points at the built conf.d.

  Fallback is modelled the way Skia, Pango, and Qt pick a glyph: the first
  font in `fc-match -s <family>` order whose charset covers the codepoint.
  `fc-match "<family>:charset=..."` scores charset as one weak element and
  returns fonts no app would pick, so it is not used.

  Verifies, per configuration:
  - U+1F600 resolves to Twitter Color Emoji for sans-serif, serif,
    monospace, and emoji.
  - U+1F600 resolves to Twitter Color Emoji for the named families Noto Sans
    and Liberation Sans when the request carries lang=und-zsye. Chromium,
    Pango, and Qt 6.9+ segment emoji-presentation characters and request
    them that way. A plain named-family request still reaches DejaVu Sans
    first, because fontconfig ranks DejaVuSans's PostScript name close to
    any "... Sans" request above every weak family. A scan rule cannot
    strip DejaVu's emoji, because NixOS pre-builds the font cache without
    user rules.
  - emoji resolves U+2615 to Twitter Color Emoji, the path apps that segment
    emoji-presentation characters take.
  - the resolved Twemoji file carries a CBDT or COLR table, read with
    fonttools. fontconfig's `color` property is true for the OpenType-SVG
    build too, which Chromium, Qt, and GTK draw in monochrome.
  - `fc-match -a emoji` lists Noto Color Emoji after Twitter Color Emoji.
    `-s` would trim Noto out, so `-a` is used.
  - for sans-serif, serif, and monospace, space, `1`, and `#` resolve to the
    same font as `A`, never to Twemoji. Twemoji covers those codepoints, so
    they catch Twemoji ordered ahead of a primary font, which `A` cannot.
  - sans-serif resolves `한` to the same font as `A`.

  It cannot see whether a running app draws the glyph in color; confirm that on
  hardware. Every failure is collected in one build.
*/
{ pkgs, self }:
let
  inherit (pkgs.lib) concatMapStrings escapeShellArg;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: escapeShellArg (toString value);

  twemoji = "Twitter Color Emoji";

  emojiFamilies = [
    "sans-serif"
    "serif"
    "monospace"
    "emoji"
    "Noto Sans:lang=und-zsye"
    "Liberation Sans:lang=und-zsye"
  ];

  textFamilies = [
    "sans-serif"
    "serif"
    "monospace"
  ];

  # Space, `1`, and `#`: ASCII codepoints Twemoji also covers.
  sharedAscii = [
    "20"
    "31"
    "23"
  ];

  checkHost =
    entry:
    let
      inherit (entry) config name;
      fontsDir = "${config.system.build.etc}/etc/fonts";
      conf = "$TMPDIR/${name}-fonts.conf";
      expectFont = family: codepoint: expected: ''
        actual="$(first_cover ${esc family} ${esc codepoint})"
        if [ "$actual" != ${expected} ]; then
          echo "$host: ${family} U+${codepoint} resolves to '$actual', not "${expected} >&2
          failed=1
        fi
      '';
    in
    ''
      host=${esc name}
      if [ ! -e ${esc "${fontsDir}/fonts.conf"} ] || [ ! -d ${esc "${fontsDir}/conf.d"} ]; then
        echo "$host: built /etc lacks fonts/fonts.conf or fonts/conf.d" >&2
        failed=1
      else
        sed "s#/etc/fonts/conf.d#${fontsDir}/conf.d#" ${esc "${fontsDir}/fonts.conf"} > "${conf}"
        export FONTCONFIG_FILE="${conf}"

        ${concatMapStrings (family: expectFont family "1f600" (esc twemoji)) emojiFamilies}
        ${expectFont "emoji" "2615" (esc twemoji)}

        # grep reads files rather than pipes: under the builder's pipefail, an
        # early grep -q match breaks the writer's pipe and reads as a miss.
        file="$(first_cover_file emoji 1f600)"
        if [ -z "$file" ]; then
          echo "$host: no font covers U+1F600 for emoji" >&2
          failed=1
        else
          ttx -l "$file" > emoji-tables.txt
          if ! grep -Eq '^ +(CBDT|COLR) ' emoji-tables.txt; then
            echo "$host: $file carries no CBDT or COLR color table" >&2
            failed=1
          fi
        fi

        fc-match -a -f '%{family[0]}\n' emoji > emoji-order.txt
        if [ "$(head -n 1 emoji-order.txt)" != ${esc twemoji} ]; then
          echo "$host: the emoji alias does not list ${twemoji} first" >&2
          failed=1
        fi
        tail -n +2 emoji-order.txt > emoji-fallbacks.txt
        if ! grep -Fxq 'Noto Color Emoji' emoji-fallbacks.txt; then
          echo "$host: the emoji alias does not list Noto Color Emoji after ${twemoji}" >&2
          failed=1
        fi

        ${concatMapStrings (family: ''
          primary="$(first_cover ${esc family} 41)"
          if [ -z "$primary" ] || [ "$primary" = ${esc twemoji} ]; then
            echo "$host: ${family} has no primary font for A" >&2
            failed=1
          fi
          ${concatMapStrings (codepoint: expectFont family codepoint ''"$primary"'') sharedAscii}
        '') textFamilies}
        sans_primary="$(first_cover sans-serif 41)"
        ${expectFont "sans-serif" "d55c" ''"$sans_primary"''}

        unset FONTCONFIG_FILE
      fi
    '';
in
pkgs.runCommand "emoji-font-tests"
  {
    nativeBuildInputs = [
      pkgs.fontconfig
      pkgs.gnugrep
      pkgs.gnused
      pkgs.python3Packages.fonttools
    ];
  }
  ''
    export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"
    ${configurations.guard}
    failed=0

    # Prints the file of the first font in family's fallback order that
    # covers the hex codepoint, the way Skia, Pango, and Qt pick a glyph.
    first_cover_file() {
      first_cover_entry "$1" "$2" | cut -f 2
    }

    # Prints the family of that font. It comes from the sorted face itself,
    # because fc-query on a font collection names the collection's first face.
    first_cover() {
      first_cover_entry "$1" "$2" | cut -f 1
    }

    # Prints "family<TAB>file" for that font. The covering set is cached per
    # host and codepoint.
    first_cover_entry() {
      covering="covering-$host-$2.txt"
      if [ ! -e "$covering" ]; then
        fc-list ":charset=$2" file | sed 's/: *$//' | sort -u > "$covering"
      fi
      fc-match -s -f '%{family[0]}\t%{file}\n' "$1" | while IFS="$(printf '\t')" read -r family file; do
        if grep -qxF "$file" "$covering"; then
          printf '%s\t%s\n' "$family" "$file"
          break
        fi
      done
    }

    ${concatMapStrings checkHost configurations.entries}

    if [ "$failed" -ne 0 ]; then
      exit 1
    fi
    touch $out
  ''
