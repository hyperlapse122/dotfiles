{ config, pkgs, ... }:
let
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
in
{
  home.packages = [
    (tools.agentUsage.override {
      syntheticKeyFile = "${import ../security/cli-auth-directory.nix config.my}/synthetic_api_key";
    })
  ];
}
