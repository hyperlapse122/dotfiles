/*
  Helper interface:

    configurations = import ./lib/configurations.nix { inherit pkgs self; };

  `fixtures` may also be passed (tests/lib/linux-fixtures.nix), so a caller
  that already built the fixture hosts does not assemble them again.

  Turns `self.nixosConfigurations` into the one list every host-dependent check
  iterates, so a host added under hosts/ is covered the day it is added and no
  check names a host.

  - `entries`: one `{ name, config, bootstrap, user }` per configuration, where
    `name` is the flake output name, `bootstrap` is `config.my.bootstrap`, and
    `user` is the `h82` Home Manager configuration (`{ }` when absent, so a
    removed user fails inside the builder rather than during evaluation).
    Checks identify a bootstrap output by `bootstrap`, never by the output
    name, because both outputs of a host share one `networking.hostName`.
  - `entryOf name host`: the same entry shape for any evaluated host, such as
    one re-evaluated with `extendModules`.
  - `production` and `bootstraps`: `entries` split by `bootstrap`.
  - `linuxFixtures`: the non-NixOS fixture hosts of the builder's
    architecture, each `{ name, fixture, bootstrap, host }`.
  - `guard`: a script fragment that fails the builder when `entries` is empty
    or holds no bootstrap output. Every check splices it before its per-entry
    assertions, so an empty list is a failure, never a silent pass.
  - `withTrait label predicate`: `{ enabled, disabled, guard }` for the trait
    `predicate config` computes, where `label` is the trait's option path
    (`my.printing.enable`). `enabled` and `disabled` split `entries`. When
    no production configuration enables the trait, `enabled` holds each
    production configuration re-evaluated with `label` forced to `true`, and
    when no configuration leaves it off, `disabled` holds each production
    configuration re-evaluated with it forced to `false`, so neither branch
    covers zero production configurations. `guard` fails the builder when
    `enabled` still holds no production configuration with the trait on,
    which catches a forced value that stopped taking effect.
  - `withTraitForcedOff label entry` and `withTraitForcedOn label entry`: a
    production `entry` re-evaluated with the option at `label` forced to
    `false` or `true`, named after the forced option.

  - `userEntries`: one `{ name, kind, bootstrap, user }` per Home Manager
    user environment the flake builds for this architecture: the NixOS
    configurations' `h82` users (`kind = "nixos"`) and the standalone Home
    Manager outputs of the non-NixOS fixture hosts (`kind = "linux"`). Checks
    that assert only Home Manager state run over this list, so they cover
    both host kinds.
  - `userGuard`: fails the builder when `userEntries` holds no bootstrap
    output or no entry of either kind.

  Trait options are read without `or` fallbacks: the shared profile imports
  every trait module, so each trait option exists on every configuration and a
  missing one is an evaluation error worth seeing.
*/
{
  pkgs,
  self,
  # tests/lib/linux-fixtures.nix. The flake passes the list it already built,
  # so the fixtures are assembled once per evaluation.
  fixtures ? import ./linux-fixtures.nix { inherit (self) inputs; },
}:
let
  inherit (pkgs) lib;

  entryOf = name: host: {
    inherit name;
    inherit (host) config;
    bootstrap = host.config.my.bootstrap;
    user = host.config.home-manager.users.h82 or { };
  };

  entries = lib.mapAttrsToList entryOf self.nixosConfigurations;

  # A production configuration with the trait at `label` forced off, for a
  # fleet in which every configuration enables it.
  withTraitForcedOff =
    label: entry:
    entryOf "${entry.name} with ${label} forced off" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [ (lib.setAttrByPath (lib.splitString "." label) (lib.mkForce false)) ];
      }
    );

  # The mirror image, for a fleet in which no production configuration
  # enables the trait.
  withTraitForcedOn =
    label: entry:
    entryOf "${entry.name} with ${label} forced on" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [ (lib.setAttrByPath (lib.splitString "." label) (lib.mkForce true)) ];
      }
    );

  production = lib.filter (entry: !entry.bootstrap) entries;

  # Only fixtures of the builder's architecture: a check interpolates their
  # store paths, and another architecture's paths cannot build here.
  linuxFixtures = lib.filter (entry: entry.host.system == pkgs.stdenv.hostPlatform.system) fixtures;

  userEntries =
    map (entry: {
      inherit (entry) name bootstrap user;
      kind = "nixos";
    }) entries
    ++ map (entry: {
      inherit (entry) name bootstrap;
      kind = "linux";
      user = entry.host.home.config;
    }) linuxFixtures;
in
{
  inherit
    entries
    entryOf
    linuxFixtures
    production
    userEntries
    withTraitForcedOff
    withTraitForcedOn
    ;

  userGuard =
    let
      missing = lib.filter (kind: !lib.any (entry: entry.kind == kind) userEntries) [
        "nixos"
        "linux"
      ];
    in
    lib.optionalString (missing != [ ]) ''
      echo ${lib.escapeShellArg "tests/lib/configurations.nix: no Home Manager user of kind ${lib.concatStringsSep ", " missing}, so this check would cover no such host"} >&2
      exit 1
    ''
    + lib.optionalString (lib.all (entry: !entry.bootstrap) userEntries) ''
      echo 'tests/lib/configurations.nix: no Home Manager user comes from a bootstrap output, so this check would cover none' >&2
      exit 1
    '';

  bootstraps = lib.filter (entry: entry.bootstrap) entries;

  guard =
    if entries == [ ] then
      ''
        echo 'tests/lib/configurations.nix: self.nixosConfigurations is empty, so this check would cover no configuration' >&2
        exit 1
      ''
    else
      lib.optionalString (lib.all (entry: !entry.bootstrap) entries) ''
        echo 'tests/lib/configurations.nix: no configuration sets my.bootstrap, so this check would cover no bootstrap output' >&2
        exit 1
      '';

  withTrait =
    label: predicate:
    let
      isOn = entry: predicate entry.config;
      on = lib.filter isOn entries;
      off = lib.filter (entry: !isOn entry) entries;
      enabled =
        on
        ++ lib.optionals (!lib.any (entry: !entry.bootstrap) on) (map (withTraitForcedOn label) production);
    in
    {
      inherit enabled;
      disabled = if off != [ ] then off else map (withTraitForcedOff label) production;
      guard = lib.optionalString (!lib.any (entry: !entry.bootstrap && isOn entry) enabled) ''
        echo ${lib.escapeShellArg "tests/lib/configurations.nix: no production configuration enables ${label}, even one re-evaluated with it forced on, so this check's positive branch would cover no configuration"} >&2
        exit 1
      '';
    };
}
