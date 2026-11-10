/*
  Check interface:

    import ./tests/nr.nix { inherit pkgs self; }

  Asserts the declarative wiring of the nixos-rebuild helper on every
  configuration `tests/lib/configurations.nix` yields and drives the packaged
  `nr` binary through `tests/nr.sh`:

  - programs.zsh.shellAliases maps nrs, nrb, nrt and nrd onto the four helper
    subcommands.
  - The packaged nr helper is in the user package list, ships an executable
    bin/nr with substituted nvd and git store paths, and retains no
    unsubstituted @[A-Z_]+@ placeholders.
  - environment.etc."nixos-host-variant" is enabled and reads bootstrap on a
    configuration whose `my.bootstrap` is set and production otherwise. The
    expected word comes from the helper's `bootstrap` field, never from the
    marker's own text.
  - `tests/nr.sh` passes against the packaged `nr` binary across flake-ref
    resolution, `--host` / hostname default, non-repo / missing-`flake.nix`
    errors, untracked-file warnings, `NR_VARIANT_FILE` bootstrap refusal,
    `/run/current-system` vs `/nix/var/nix/profiles/system` diff targets,
    flag validation, and stubbed `nvd` post-rebuild diff behavior.

  The marker is checked through its enable flag and its resolved target rather
  than its attribute name, and the helper is checked through the built script
  rather than a package-list entry, because a package list is a proxy the
  script does not read.

  The helper's guard runs first, so an empty configuration list, or one with no
  bootstrap output, fails the build instead of passing it. The builder collects
  every configuration failure before running the CLI suite and exiting.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  packagedNr = (import ../packages/nix-tools.nix { inherit pkgs; }).nr;

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  expectedAliases = {
    nrs = "nr switch";
    nrb = "nr boot";
    nrt = "nr test";
    nrd = "nr build";
  };

  assertAliases =
    entry:
    let
      aliases = entry.user.programs.zsh.shellAliases or { };
      wrongAliases = lib.attrNames (
        lib.filterAttrs (name: want: (aliases.${name} or null) != want) expectedAliases
      );
    in
    ''
      if [ ${esc (builtins.toJSON wrongAliases)} != '[]' ]; then
        ${fail "${entry.name}: these zsh aliases are missing or point at the wrong subcommand: ${builtins.toJSON wrongAliases}"}
      fi
    '';

  assertHelper =
    entry:
    let
      nrPackage = lib.lists.findFirst (p: (p.pname or "") == "nr") null (entry.user.home.packages or [ ]);
    in
    if nrPackage == null then
      fail "${entry.name}: the packaged nr helper is missing from the user package list"
    else
      ''
        nr=${esc "${nrPackage}/bin/nr"}
        if [ ! -x "$nr" ]; then
          ${fail "${entry.name}: the nr package ships no bin/nr executable"}
        else
          if ! grep -q ${esc "${pkgs.nvd}/bin/nvd"} "$nr"; then
            ${fail "${entry.name}: the built nr helper does not carry the substituted nvd store path"}
          fi
          if ! grep -q ${esc "${pkgs.git}/bin/git"} "$nr"; then
            ${fail "${entry.name}: the built nr helper does not carry the substituted git store path"}
          fi
          # Any surviving placeholder, not just @NVD@: a check that names one
          # token passes while another substitution is silently dropped.
          if grep -qE '@[A-Z_]+@' "$nr"; then
            ${fail "${entry.name}: the built nr helper still contains an unsubstituted placeholder"}
          fi
        fi
      '';

  assertMarker =
    entry:
    let
      marker = lib.lists.findFirst (e: (e.target or "") == "nixos-host-variant") null (
        lib.attrValues (entry.config.environment.etc or { })
      );
      expected = if entry.bootstrap then "bootstrap" else "production";
    in
    if marker == null then
      fail "${entry.name}: no /etc entry targets nixos-host-variant"
    else
      ''
        if [ ${esc (builtins.toJSON (marker.enable or false))} != "true" ]; then
          ${fail "${entry.name}: the nixos-host-variant entry is declared but not enabled"}
        fi
        if [ ${esc (lib.strings.trim (marker.text or ""))} != ${esc expected} ]; then
          ${fail "${entry.name}: the configuration reports the wrong host variant, expected ${expected}"}
        fi
      '';
in
pkgs.runCommand "nr-tests"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.gnugrep
    ];
  }
  ''
    set -x
    export HOME=$TMPDIR
    ${configurations.guard}
    failed=0

    ${lib.concatMapStringsSep "\n" (
      entry:
      lib.concatStringsSep "\n" [
        (assertAliases entry)
        (assertHelper entry)
        (assertMarker entry)
      ]
    ) configurations.entries}

    if [ "$failed" != 0 ]; then
      exit 1
    fi

    bash ${./nr.sh} "${packagedNr}/bin/nr"
    touch $out
  ''
