# The values of every option modules/shared/host.nix declares, read from a
# configuration that imports it. NixOS hands these to its Home Manager user, so
# a trait added to the shared module reaches the user without another edit.
# Only the declared options are copied: a NixOS-only option, even one declared
# under the same attribute as a shared one, stays on the system.
#
#   hostFacts = import ./lib/host-facts.nix { inherit lib; };
#   hostFacts.of config.my  -> { bootstrap, hostName, kind, user, t3, ... }
{ lib }:
let
  declared = (import ../modules/shared/host.nix { inherit lib; }).options.my;

  project =
    options: values:
    lib.mapAttrs (
      name: option: if lib.isOption option then values.${name} else project option values.${name}
    ) options;

in
{
  of = project declared;
}
