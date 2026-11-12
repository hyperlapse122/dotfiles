/*
  Check interface:

    import ./tests/kde-power.nix { inherit pkgs self; }

  Asserts that on AC power Plasma neither dims nor turns off the screen and
  never suspends or hibernates by itself, on every configuration
  `tests/lib/configurations.nix` yields, production and bootstrap alike.

  Reads the materialised /etc/xdg/powerdevilrc through kreadconfig6 with an
  empty HOME and XDG_CONFIG_DIRS pointing at it, so the values are the ones
  PowerDevil resolves, not the text the module writes. KConfig nests a group
  only in the `[AC][Display]` form; a `[AC/Display]` header names an unrelated
  top-level group, and the read below falls through to `UNSET`.

  Verifies, per configuration:
  - [AC][SuspendAndShutdown] AutoSuspendAction is 0 (no action). PowerDevil's
    own default on a machine that can suspend is to sleep after 15 minutes.
  - [AC][Display] TurnOffDisplayWhenIdle is false. PowerDevil's default turns
    the screen off after 10 minutes, and while it is false the screen also
    stays on behind the lock screen.
  - [AC][Display] DimDisplayWhenIdle is false.

  It cannot see whether a running session stays awake; confirm that on
  hardware. Every failure is collected in one build.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  etcFile = import ./lib/etc-file.nix { inherit lib; };

  esc = value: lib.escapeShellArg (toString value);

  kread = "${pkgs.kdePackages.kconfig}/bin/kreadconfig6";

  expected = [
    {
      group = "SuspendAndShutdown";
      key = "AutoSuspendAction";
      value = "0";
    }
    {
      group = "Display";
      key = "TurnOffDisplayWhenIdle";
      value = "false";
    }
    {
      group = "Display";
      key = "DimDisplayWhenIdle";
      value = "false";
    }
  ];

  checkHost =
    entry:
    let
      inherit (entry) name;
      file = etcFile entry.config "xdg/powerdevilrc";
    in
    if file == null then
      ''
        echo ${esc "${name}: the built system declares no /etc/xdg/powerdevilrc"} >&2
        failed=1
      ''
    else
      ''
        xdg=$(mktemp -d)
        ln -s ${esc file} "$xdg/powerdevilrc"
        ${lib.concatMapStrings (e: ''
          actual=$(HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/home/.config" XDG_CONFIG_DIRS="$xdg" \
            ${kread} --file powerdevilrc --group AC --group ${e.group} --key ${e.key} --default UNSET)
          if [ "$actual" != ${esc e.value} ]; then
            echo ${esc "${name}: [AC][${e.group}] ${e.key} resolves to"} "'$actual'," ${esc "expected ${e.value}"} >&2
            failed=1
          fi
        '') expected}
      '';
in
pkgs.runCommand "kde-power-tests" { LANG = "C.UTF-8"; } ''
  ${configurations.guard}
  failed=0
  mkdir -p "$TMPDIR/home/.config"

  ${lib.concatMapStringsSep "\n" checkHost configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
