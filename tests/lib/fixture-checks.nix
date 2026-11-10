# The build checks of the non-NixOS fixture hosts for one system: each
# fixture's Home Manager activation package and system-manager toplevel, both
# variants. A fixture builds only on its own architecture, so each system's
# checks carry only that system's fixtures.
#
#   fixtureChecksFor = import ./tests/lib/fixture-checks.nix { inherit lib linuxFixtures; };
#   fixtureChecksFor "aarch64-linux" -> { non-nixos-home-<name> = ...; non-nixos-system-<name> = ...; }
{ lib, linuxFixtures }:
system:
lib.listToAttrs (
  lib.concatMap (entry: [
    {
      name = "non-nixos-home-${entry.name}";
      value = entry.host.home.activationPackage;
    }
    {
      name = "non-nixos-system-${entry.name}";
      value = entry.host.systemManager;
    }
  ]) (lib.filter (entry: entry.host.system == system) linuxFixtures)
)
