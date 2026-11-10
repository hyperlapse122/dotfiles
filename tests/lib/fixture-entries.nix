# The production and bootstrap entry of each fixture host one assembly
# builds, with the fake secrets every fixture decrypts. Shared by
# tests/lib/linux-fixtures.nix and tests/lib/darwin-fixtures.nix.
#
#   import ./fixture-entries.nix { inherit lib; } mkHost fixtureNames
#   -> [ { name, fixture, bootstrap, host } ... ]
{ lib }:
mkHost: fixtureNames:
lib.concatMap (
  fixture:
  map
    (bootstrap: {
      name = if bootstrap then "${fixture}-bootstrap" else fixture;
      inherit fixture bootstrap;
      host = mkHost {
        hostName = fixture;
        dir = ../fixtures/hosts + "/${fixture}";
        inherit bootstrap;
        extraModules.home = [ ./fake-secrets-module.nix ];
      };
    })
    [
      false
      true
    ]
) fixtureNames
