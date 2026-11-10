/*
  Assembles a macOS host from its directory. A host directory is a macOS host
  when its `host.nix` evaluates to
  `{ kind = "darwin"; system = "aarch64-darwin"; }`; its `default.nix` sets the
  host's traits and account through the shared host options.

    mkDarwinHost = import ./lib/darwin-host.nix { inherit inputs; };
    mkDarwinHost { hostName, dir, bootstrap, extraModules ? { } }
      -> darwinSystem

  nix-darwin applies the system layer and Home Manager runs inside it, as on
  NixOS, so one activation applies both. The user sees the same host facts and
  traits as the system. The flake and the checks' fixture hosts both go
  through this function. `extraModules.home` and `extraModules.system` let a
  fixture supply test-only values, such as fake secret files, to Home Manager
  and to the system.
*/
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  hostFacts = import ./host-facts.nix { inherit lib; };

  supportedSystems = [ "aarch64-darwin" ];

  # One binding for the kind: hostKind gates imports, which cannot read
  # config without recursing, and my.kind carries it everywhere else.
  kind = "darwin";
in
{
  hostName,
  dir,
  bootstrap,
  extraModules ? { },
}:
let
  meta = import (dir + "/host.nix");

  system =
    if meta.kind or null != kind then
      throw "${hostName}: host.nix must set kind = \"darwin\""
    else if !lib.elem (meta.system or null) supportedSystems then
      throw "${hostName}: host.nix sets system = ${
        builtins.toJSON (meta.system or null)
      }, which is not one of ${lib.concatStringsSep ", " supportedSystems}"
    else
      meta.system;
in
inputs.nix-darwin.lib.darwinSystem {
  specialArgs = { inherit inputs; };
  modules = [
    inputs.home-manager.darwinModules.home-manager
    inputs.nix-homebrew.darwinModules.nix-homebrew
    ../modules/shared/host.nix
    dir
    ../modules/darwin/profile.nix
    (
      { config, ... }:
      {
        nixpkgs.hostPlatform = system;
        nixpkgs.config.allowUnfree = true;

        my.hostName = hostName;
        my.bootstrap = bootstrap;
        my.kind = kind;

        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.extraSpecialArgs = {
          inherit inputs;
          hostKind = kind;
        };
        # The user sees the same host facts and traits as the system.
        home-manager.sharedModules = [
          ../modules/shared/host.nix
          { my = hostFacts.of config.my; }
        ]
        ++ (extraModules.home or [ ]);
        home-manager.users.${config.my.user.name} = import ../home/h82;
      }
    )
  ]
  ++ (extraModules.system or [ ]);
}
