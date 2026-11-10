/*
  Helper interface:

    darwinFixtures = import ./lib/darwin-fixtures.nix { inherit inputs; };

  The macOS fixture hosts under tests/fixtures/hosts/, assembled through the
  same lib/darwin-host.nix the flake uses for real hosts. They stand in for
  the Mac that has not been bought, which would need card-encrypted material
  under secrets/.

  Returns one `{ name, fixture, bootstrap, host }` per fixture and variant,
  where `name` is the output name (`<fixture>` or `<fixture>-bootstrap`),
  `fixture` the directory name, and `host` the darwinSystem. Fixture names are
  read from the directory, never written out, so host-name-guard can keep
  them out of code.
*/
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  mkDarwinHost = import ../../lib/darwin-host.nix { inherit inputs; };

  fixtureNames = (import ../../lib/hosts.nix { inherit lib; } ../fixtures/hosts).darwin;
in
import ./fixture-entries.nix { inherit lib; } (
  args:
  mkDarwinHost (
    args
    // {
      extraModules = args.extraModules // {
        system = [ ./fake-darwin-secrets-module.nix ];
      };
    }
  )
) fixtureNames
