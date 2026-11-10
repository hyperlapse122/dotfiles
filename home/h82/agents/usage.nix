{ config, pkgs, ... }:
let
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
in
{
  home.packages = [
    (tools.agentUsage.override {
      syntheticKeyFile =
        if config.my.kind == "nixos" then
          "/run/secrets/cli-auth/synthetic_api_key"
        else
          "${config.my.secrets.stateDir}/synthetic_api_key";
    })
  ];
}
