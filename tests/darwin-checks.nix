{ pkgs, inputs }:
let
  inherit (inputs) self;
  entries = pkgs.lib.mapAttrsToList (name: host: {
    inherit name;
    inherit (host.config.my) kind bootstrap;
    user = host.config.home-manager.users.${host.config.my.user.name};
  }) self.darwinConfigurations;
in
import ./shared-checks.nix { inherit pkgs inputs; }
// {
  agent-unmanaged = import ./agent-unmanaged.nix {
    inherit pkgs entries;
    systems = map (
      host: pkgs.writeText "system-activation" host.config.system.activationScripts.script.text
    ) (builtins.attrValues self.darwinConfigurations);
  };
  zsh-prezto = import ./zsh-prezto.nix { inherit pkgs entries; };
  omp = import ./omp.nix {
    inherit pkgs entries;
  };
  nix-settings = import ./nix-settings.nix {
    inherit pkgs;
    configurations = self.darwinConfigurations;
  };
  darwin-outputs = import ./darwin-outputs.nix {
    inherit pkgs self;
    darwinFixtures = import ./lib/darwin-fixtures.nix { inherit inputs; };
    inherit (self) darwinConfigurations;
  };
}
