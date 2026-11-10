/*
  Assembles a non-NixOS host from its directory. A host directory is a
  non-NixOS host when it holds `host.nix`, which evaluates to
  `{ kind = "linux"; system = "<arch>-linux"; }`; its `default.nix` sets the
  host's traits and account through the shared host options.

    mkLinuxHost = import ./lib/linux-host.nix { inherit inputs; };
    mkLinuxHost { hostName, dir, bootstrap, extraModules ? { } }
      -> { system, home, systemManager }

  `home` is the standalone Home Manager configuration of the user profile with
  its desktop parts gated off, and `systemManager` is the system-manager
  toplevel for the system layer. Both see the same host facts. The flake and
  the checks' fixture hosts both go through this function, so the two cannot
  assemble a host differently. `extraModules.home` lets a fixture supply
  test-only values, such as fake secret files.
*/
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;

  supportedSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  # One nixpkgs per architecture, shared by every host and variant this
  # function assembles.
  pkgsFor = lib.genAttrs supportedSystems (
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
    }
  );
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
    if meta.kind or null != "linux" then
      throw "${hostName}: host.nix must set kind = \"linux\""
    else if !lib.elem (meta.system or null) supportedSystems then
      throw "${hostName}: host.nix sets system = ${
        builtins.toJSON (meta.system or null)
      }, which is not one of ${lib.concatStringsSep ", " supportedSystems}"
    else
      meta.system;

  pkgs = pkgsFor.${system};

  # One binding for the kind: hostKind gates imports, which cannot read
  # config without recursing, and my.kind carries it everywhere else.
  kind = "linux";

  hostFacts = {
    my = {
      inherit hostName bootstrap kind;
    };
  };
in
{
  inherit system;

  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      inherit inputs;
      hostKind = kind;
    };
    modules = [
      ../modules/shared/host.nix
      dir
      hostFacts
      ../home/h82
    ]
    ++ (extraModules.home or [ ]);
  };

  systemManager = inputs.system-manager.lib.makeSystemConfig {
    modules = [
      ../modules/shared/host.nix
      dir
      hostFacts
      ../modules/system-manager
      { nixpkgs.hostPlatform = system; }
    ];
  };
}
