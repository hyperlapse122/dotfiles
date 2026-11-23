{ pkgs }:
let
  inherit (pkgs) lib;
in
harness: enable:
import ../../home/h82/agents/quality-hooks.nix {
  inherit pkgs lib harness;
  config.my.agentHooks = {
    ${harness} = {
      inherit enable;
      preShell = true;
      freezeTests = true;
    };
  };
}
