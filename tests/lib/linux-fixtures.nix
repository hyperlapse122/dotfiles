/*
  Helper interface:

    linuxFixtures = import ./lib/linux-fixtures.nix { inherit inputs; };

  The non-NixOS Linux fixture hosts under tests/fixtures/hosts/, assembled through
  the same lib/linux-host.nix the flake uses for real hosts. They stand in for
  real non-NixOS hosts, which need card-encrypted material under secrets/ and
  so cannot live in hosts/ for testing.

  Returns one `{ name, fixture, bootstrap, host }` per fixture and variant,
  where `name` is the output name (`<fixture>` or `<fixture>-bootstrap`),
  `fixture` the directory name, and `host` the result of mkLinuxHost
  (`{ system, home, systemManager }`). Fixture names are read from the
  directory, never written out, so host-name-guard can keep them out of code.
*/
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  mkLinuxHost = import ../../lib/linux-host.nix { inherit inputs; };

  fixtureNames = (import ../../lib/hosts.nix { inherit lib; } ../fixtures/hosts).linux;
in
import ./fixture-entries.nix { inherit lib; } mkLinuxHost fixtureNames
