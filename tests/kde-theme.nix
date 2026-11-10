/*
  Check interface:

    import ./tests/kde-theme.nix { inherit pkgs self; }

  Asserts that Plasma switches between Breeze Light and Breeze Dark by time of
  day, with Breeze Light as the system-wide baseline, both in the KDE defaults
  and in h82's own kdeglobals.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike, by reading the materialised
  /etc/xdg/kdeglobals and system path rather than the options that render
  them:
  - [KDE] AutomaticLookAndFeel is true, DefaultLightLookAndFeel is
    org.kde.breeze.desktop, and DefaultDarkLookAndFeel is
    org.kde.breezedark.desktop.
  - [KDE] LookAndFeelPackage is org.kde.breeze.desktop.
  - [General] ColorScheme is BreezeLight.
  - [Icons] Theme is breeze.
  - every [Colors:*], [ColorEffects:*], and [WM] entry of the packaged
    BreezeLight.colors, nested groups included, carries its packaged value.
    KColorScheme falls back to built-in colors when the groups are absent, so
    the scheme name alone is not enough. The light Window background is also
    checked to differ from BreezeDark.colors, so a dark scheme cannot pass.
  - the existing TerminalApplication and Locale entries survive.
  - the system path ships the lookandfeelautoswitcher kded module, which is
    what reads AutomaticLookAndFeel during a session.

  Verifies, on every configuration as well (home/h82/desktop/kde/theme.nix is
  not gated on my.bootstrap), by running the kdeTheme Home Manager activation
  against three fixture HOMEs, with XDG_CONFIG_DIRS set as in a session: a
  ~/.config/kdedefaults holding the Breeze Dark scheme and icon theme, as
  startplasma writes them for a night login, then the built /etc/xdg.
  Each seeds AutomaticLookAndFeel false, stale light and dark package names,
  and a ColorSchemeHash, so the system defaults cannot mask a missing write:
  one holds the Breeze Dark identity and color groups, one holds a value no
  light entry has in every copied entry and identity key, and one names the
  Breeze Light package and scheme over Breeze Dark's color groups, the
  mismatch the deletions repair. On each fixture:
  - the effective (user, else system) values are AutomaticLookAndFeel true
    and the Breeze and Breeze Dark packages.
  - [General] ColorScheme, [General] ColorSchemeHash, and [Icons] Theme are
    gone from the user file, with no Key[$d] deletion marker left either.
    Login writes the scheduled package's scheme and icon theme to
    ~/.config/kdedefaults, which a user entry or marker outranks, and
    re-applies colors only when the hash no longer matches.
  - kreadconfig6 resolves ColorScheme and the icon theme to the kdedefaults
    values, so nothing in the user file masks them.
  - an unrelated user key survives.
  On the Breeze Dark fixture, the user's LookAndFeelPackage and the effective
  value of every copied color entry stay dark, so an activation that forces
  Breeze Light back in fails.

  It cannot see whether a running session switches; confirm that on hardware.
  Every failure is collected in one build.
*/
{ pkgs, self }:
let
  inherit (pkgs.lib)
    attrNames
    concatMapStringsSep
    escapeShellArg
    optionalString
    ;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: escapeShellArg (toString value);

  colorSchemes = "${pkgs.kdePackages.breeze}/share/color-schemes";

  kread = "${pkgs.kdePackages.kconfig}/bin/kreadconfig6";

  lightPackage = "org.kde.breeze.desktop";
  darkPackage = "org.kde.breezedark.desktop";

  # The groups modules/nixos/desktop/desktop.nix copies out of a packaged
  # scheme.
  copiedGroups = ''/^\[/ { keep = ($0 ~ /^\[(Colors|ColorEffects):/ || $0 == "[WM]") }'';

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  etcAssertions =
    entry:
    let
      kdeglobals = "${entry.config.system.build.etc}/etc/xdg/kdeglobals";
      switcher = "${entry.config.system.path}/lib/qt-6/plugins/kf6/kded/lookandfeelautoswitcher.so";
      expectKey = group: key: value: ''
        if [ "$(ini_get ${esc kdeglobals} ${esc group} ${esc key})" != ${esc value} ]; then
          ${fail "${entry.name}: /etc/xdg/kdeglobals [${group}] ${key} is not ${value}"}
        fi
      '';
    in
    ''
      if [ ! -f ${esc kdeglobals} ]; then
        ${fail "${entry.name}: /etc/xdg/kdeglobals is missing"}
      else
        ${expectKey "KDE" "AutomaticLookAndFeel" "true"}
        ${expectKey "KDE" "DefaultLightLookAndFeel" lightPackage}
        ${expectKey "KDE" "DefaultDarkLookAndFeel" darkPackage}
        ${expectKey "KDE" "LookAndFeelPackage" lightPackage}
        ${expectKey "General" "ColorScheme" "BreezeLight"}
        ${expectKey "Icons" "Theme" "breeze"}
        ${expectKey "General" "TerminalApplication" "ghostty"}
        ${expectKey "Locale" "Language" "ko:en_US"}
        expect_scheme ${esc "${entry.name}: /etc/xdg/kdeglobals"} "$light_entries" ini_get ${esc kdeglobals}
      fi
      if [ ! -f ${esc switcher} ]; then
        ${fail "${entry.name}: the system path ships no lookandfeelautoswitcher kded module"}
      fi
    '';

  # A user kdeglobals with the given identity, automatic switching off, stale
  # package names, and a ColorSchemeHash, followed by the given color groups.
  userFixture =
    {
      scheme,
      icons,
      package,
      colors,
    }:
    ''
      printf '[General]\nBrowserApplication=fixture.desktop\nColorScheme=%s\nColorSchemeHash=stale\n\n' ${esc scheme}
      printf '[Icons]\nTheme=%s\n\n' ${esc icons}
      printf '[KDE]\nAutomaticLookAndFeel=false\nDefaultDarkLookAndFeel=stale\nDefaultLightLookAndFeel=stale\nLookAndFeelPackage=%s\n\n' ${esc package}
      ${colors}
    '';

  darkColorGroups = ''
    awk ${esc "${copiedGroups} keep { print }"} ${esc "${colorSchemes}/BreezeDark.colors"}
  '';

  # User kdeglobals fixtures the activation must convert. Breeze Dark and
  # Breeze Light share many entries (every [ColorEffects:*] one among them), so
  # `stale` seeds every copied entry and identity key with a value no light
  # entry has.
  fixtures = {
    dark = userFixture {
      scheme = "BreezeDark";
      icons = "breeze-dark";
      package = darkPackage;
      colors = darkColorGroups;
    };
    stale = userFixture {
      scheme = "stale";
      icons = "stale";
      package = "stale";
      colors = ''
        awk -F '\t' '$1 != group { group = $1; printf "[%s]\n", group } { printf "%s=stale\n", $2 }' "$light_entries"
      '';
    };
    mismatch = userFixture {
      scheme = "BreezeLight";
      icons = "breeze";
      package = lightPackage;
      colors = darkColorGroups;
    };
  };

  activationAssertions =
    entry: fixture:
    let
      data = entry.user.home.activation.kdeTheme.data or "";
      script = pkgs.writeText "${entry.name}-kde-theme.sh" data;
      label = "${entry.name}: after kdeTheme activation on the ${fixture} fixture,";
      home = "$TMPDIR/${entry.name}-${fixture}-home";
      userGlobals = "${home}/.config/kdeglobals";
      systemGlobals = "${entry.config.system.build.etc}/etc/xdg/kdeglobals";
      # A session's XDG_CONFIG_DIRS, with the kdedefaults dir startplasma
      # prepends holding the scheduled Breeze Dark scheme and icon theme.
      configDirs = "${home}/.config/kdedefaults:${entry.config.system.build.etc}/etc/xdg";
      kdeEnv = ''HOME="${home}" XDG_CONFIG_HOME="${home}/.config" XDG_CONFIG_DIRS="${configDirs}"'';
      expectEffective = group: key: expected: message: ''
        if [ "$(ini_effective "${userGlobals}" ${esc systemGlobals} ${esc group} ${esc key})" != ${esc expected} ]; then
          ${fail "${label} ${message}"}
        fi
      '';
      # A Key[$d] marker counts: it masks the cascaded value as a pin does.
      expectDeleted = group: key: ''
        if ini_mentions "${userGlobals}" ${esc group} ${esc key}; then
          ${fail "${label} the user file still sets or masks [${group}] ${key}"}
        fi
      '';
      # What KConfig itself resolves through the session's config dirs.
      expectResolved = group: key: expected: ''
        if [ "$(${kdeEnv} ${kread} --file kdeglobals --group ${esc group} --key ${esc key})" != ${esc expected} ]; then
          ${fail "${label} KConfig does not resolve [${group}] ${key} to the kdedefaults value ${expected}"}
        fi
      '';
    in
    ''
      if [ ! -s ${esc script} ]; then
        ${fail "${entry.name}: kdeTheme activation script is missing or empty"}
      else
        mkdir -p "${home}/.config/kdedefaults"
        {
          ${fixtures.${fixture}}
        } > "${userGlobals}"
        printf '[General]\nColorScheme=BreezeDark\n\n[Icons]\nTheme=breeze-dark\n' \
          > "${home}/.config/kdedefaults/kdeglobals"
        if ! ${kdeEnv} bash ${esc script} >/dev/null 2>&1; then
          ${fail "${label} the activation exited non-zero"}
        fi
        ${expectEffective "KDE" "AutomaticLookAndFeel" "true" "automatic switching is not on"}
        ${expectEffective "KDE" "DefaultLightLookAndFeel" lightPackage "the light package is not Breeze"}
        ${expectEffective "KDE" "DefaultDarkLookAndFeel" darkPackage
          "the dark package is not Breeze Dark"
        }
        ${expectDeleted "General" "ColorScheme"}
        ${expectDeleted "General" "ColorSchemeHash"}
        ${expectDeleted "Icons" "Theme"}
        ${expectResolved "General" "ColorScheme" "BreezeDark"}
        ${expectResolved "Icons" "Theme" "breeze-dark"}
        ${expectEffective "General" "BrowserApplication" "fixture.desktop"
          "an unrelated user key was lost"
        }
        ${optionalString (fixture == "dark") ''
          if [ "$(ini_get "${userGlobals}" KDE LookAndFeelPackage)" != ${esc darkPackage} ]; then
            ${fail "${label} the user LookAndFeelPackage was rewritten"}
          fi
          expect_scheme ${esc "${label} the effective"} "$dark_entries" \
            ini_effective "${userGlobals}" ${esc systemGlobals}
        ''}
      fi
    '';
in
pkgs.runCommand "kde-theme-tests"
  {
    nativeBuildInputs = [
      pkgs.gawk
      pkgs.gnugrep
    ];
  }
  ''
    ${configurations.guard}
    failed=0

    # Prints the first value of key in [group] of an INI file.
    ini_get() {
      awk -v group="[$2]" -v key="$3" '
        /^\[/ { in_group = ($0 == group); next }
        in_group && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
      ' "$1"
    }

    # Succeeds when key is present in [group] of an INI file, even with an
    # empty value.
    ini_has() {
      awk -v group="[$2]" -v key="$3" '
        /^\[/ { in_group = ($0 == group); next }
        in_group && index($0, key "=") == 1 { found = 1; exit }
        END { exit !found }
      ' "$1"
    }

    # Succeeds when [group] of an INI file sets key or carries a key[...]
    # entry, such as the Key[$d] deletion marker.
    ini_mentions() {
      awk -v group="[$2]" -v key="$3" '
        /^\[/ { in_group = ($0 == group); next }
        in_group && (index($0, key "=") == 1 || index($0, key "[") == 1) { found = 1; exit }
        END { exit !found }
      ' "$1"
    }

    # Prints what KConfig resolves: the user file's value, else the system one.
    # KConfig drops a user entry that equals the cascaded default, so a key
    # absent from the user file is not a missing write. An empty user value
    # still overrides the system one, so presence decides, not emptiness.
    ini_effective() {
      if ini_has "$1" "$3" "$4"; then
        ini_get "$1" "$3" "$4"
      else
        ini_get "$2" "$3" "$4"
      fi
    }

    # One "group<TAB>key<TAB>value" line per copied entry of a packaged scheme;
    # a nested group keeps its inner brackets, as in "Colors:Header][Inactive".
    scheme_entries() {
      awk ${esc copiedGroups}'
        /^\[/ { group = substr($0, 2, length($0) - 2); next }
        keep && index($0, "=") > 1 {
          eq = index($0, "=")
          printf "%s\t%s\t%s\n", group, substr($0, 1, eq - 1), substr($0, eq + 1)
        }
      ' "$1"
    }
    light_entries="$TMPDIR/light-entries"
    dark_entries="$TMPDIR/dark-entries"
    scheme_entries ${esc "${colorSchemes}/BreezeLight.colors"} > "$light_entries"
    scheme_entries ${esc "${colorSchemes}/BreezeDark.colors"} > "$dark_entries"
    if ! grep -q $'^WM\t' "$light_entries" || ! grep -q $'^Colors:Header\\]\\[Inactive\t' "$light_entries"; then
      ${fail "BreezeLight.colors yielded no [WM] or nested [Colors:Header][Inactive] entries"}
    fi

    # Fails once per entry of the given list whose value, resolved by the
    # given lookup command and its file arguments, differs from the packaged
    # one.
    expect_scheme() {
      label="$1"
      entries="$2"
      shift 2
      while IFS=$'\t' read -r group key value; do
        if [ "$("$@" "$group" "$key")" != "$value" ]; then
          echo "$label [$group] $key is not the packaged value" >&2
          failed=1
        fi
      done < "$entries"
    }

    dark_window="$(ini_get ${esc "${colorSchemes}/BreezeDark.colors"} Colors:Window BackgroundNormal)"
    light_window="$(ini_get ${esc "${colorSchemes}/BreezeLight.colors"} Colors:Window BackgroundNormal)"
    if [ -z "$light_window" ] || [ "$dark_window" = "$light_window" ]; then
      ${fail "BreezeLight.colors does not carry a Window background distinct from BreezeDark.colors"}
    fi

    ${concatMapStringsSep "\n" etcAssertions configurations.entries}
    ${concatMapStringsSep "\n" (
      entry: concatMapStringsSep "\n" (activationAssertions entry) (attrNames fixtures)
    ) configurations.entries}

    if [ "$failed" -ne 0 ]; then
      exit 1
    fi
    touch $out
  ''
