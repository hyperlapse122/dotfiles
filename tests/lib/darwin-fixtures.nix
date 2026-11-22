# Evaluate both variants through the production host builder using fixture secrets.
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  mkDarwinHost = import ../../lib/darwin-host.nix { inherit inputs; };

  hosts = import ../../lib/hosts.nix { inherit lib; } ../fixtures/hosts;
in
lib.mapAttrsToList (name: value: { inherit name; } // value) (
  hosts.variantsOf (
    {
      hostName,
      dir,
      bootstrap,
    }:
    {
      fixture = hostName;
      inherit bootstrap;
      host = mkDarwinHost {
        inherit hostName dir bootstrap;
        extraModules = {
          home = [ ./fake-secrets-module.nix ];
          system = [ ./fake-darwin-secrets-module.nix ];
        };
      };
    }
  ) hosts.darwin
)
