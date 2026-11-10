/*
  Assembles a NixOS host from its directory: the host's hardware, disk layout,
  and traits, the shared profile, and the h82 Home Manager user, who sees the
  same host facts and traits as the system.

    mkHost = import ./lib/nixos-host.nix { inherit inputs; };
    mkHost { hostName, bootstrap } -> nixosSystem
*/
{ inputs }:
let
  inherit (inputs.nixpkgs) lib;
  hostFacts = import ./host-facts.nix { inherit lib; };
  kind = "nixos";
in
{ hostName, bootstrap }:
lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit inputs; };
  modules = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    inputs.sops-nix.nixosModules.sops
    # The host directory precedes the profile so list-valued options keep the
    # merge order they had when each host imported the profile itself.
    ../hosts/${hostName}
    ../modules/nixos/profile.nix
    (
      { config, ... }:
      {
        networking.hostName = hostName;
        my.hostName = hostName;
        my.bootstrap = bootstrap;
        my.kind = kind;
        my.locale = {
          name = config.i18n.defaultLocale;
          language =
            config.i18n.extraLocaleSettings.LANGUAGE or config.environment.variables.LANGUAGE
              or config.i18n.extraLocaleSettings.LC_MESSAGES or config.i18n.defaultLocale;
        };
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        # specialArgs reaches NixOS modules only; the agent-plugin registry
        # needs the pinned plugin source, which is an input. hostKind gates
        # imports, which cannot read config without recursing.
        # programs._1password-gui.package carries apply = pkg.override
        # { polkitPolicyOwners }, so the desktop autostart takes the system's
        # package rather than pkgs._1password-gui.
        home-manager.extraSpecialArgs = {
          inherit inputs;
          hostKind = kind;
          onePasswordGui = config.programs._1password-gui.package;
          # The tray must match the running daemon, and has no daemon to talk
          # to where tailscaled is off.
          tailscalePackage =
            if config.services.tailscale.enable then config.services.tailscale.package else null;
        };
        # The user sees the same host facts and traits as the system.
        home-manager.sharedModules = [
          ../modules/shared/host.nix
          { my = hostFacts.of config.my; }
        ];
        home-manager.users.h82 = import ../home/h82;
      }
    )
  ];
}
