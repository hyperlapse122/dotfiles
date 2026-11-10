/*
  Check interface:

    import ./tests/host-options.nix { inherit pkgs self; }

  Guards the shared host options in modules/shared/host.nix, the one place
  host facts and traits are declared for every assembly.

  - On every NixOS and Darwin configuration, the Home Manager user sees the
    same bootstrap flag, host name, host kind, account, and traits as the
    system. A trait the flake forgets to hand to Home Manager falls back to the
    option's default there, so the user side silently disagrees with the
    system side; this compares the two values rather than either one alone.
  - No file under home/ reads `osConfig`: a standalone Home Manager output has
    no NixOS configuration behind it, so such a read only works on NixOS.

  Every comparison is rendered into the builder, so a mismatch fails the
  build with a message naming the configuration and the option, rather than
  aborting evaluation.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  darwinFixtures = map (e: {
    inherit (e) name;
    inherit (e.host) config;
    user = e.host.config.home-manager.users.${e.host.config.my.user.name};
  }) (import ./lib/darwin-fixtures.nix { inherit (self) inputs; });

  pathsOf =
    prefix: options:
    lib.concatLists (
      lib.mapAttrsToList (
        name: option:
        if lib.isOption option then [ (prefix ++ [ name ]) ] else pathsOf (prefix ++ [ name ]) option
      ) options
    );

  # Every option modules/shared/host.nix declares: the user must see each one
  # exactly as the system does. Derived from the declarations, so a new trait
  # is compared the day it is added.
  shared = pathsOf [ ] (import ../modules/shared/host.nix { inherit lib; }).options.my;
  valueOf = config: path: builtins.toJSON (lib.attrByPath ([ "my" ] ++ path) null config);

  assertEntry =
    entry:
    lib.concatMapStrings (
      path:
      let
        label = "my.${lib.concatStringsSep "." path}";
        system = valueOf entry.config path;
        user = valueOf entry.user path;
      in
      lib.optionalString (system != user) ''
        echo ${lib.escapeShellArg "${entry.name}: Home Manager sees ${label} = ${user}, the system has ${system}"} >&2
        fail=1
      ''
    ) shared;
in
pkgs.runCommand "host-options"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    home = ../home;
  }
  ''
    ${configurations.guard}
    fail=0
    ${lib.optionalString (darwinFixtures == [ ]) ''
      echo "tests/fixtures/hosts holds no macOS fixture host" >&2
      fail=1
    ''}
    ${lib.concatMapStrings assertEntry (configurations.entries ++ darwinFixtures)}
    if grep -rn -w osConfig "$home" >&2; then
      echo 'files under home/ read osConfig, which a standalone Home Manager output does not have' >&2
      fail=1
    fi
    [ "$fail" = 0 ] || exit 1
    touch "$out"
  ''
