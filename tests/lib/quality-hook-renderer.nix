{ pkgs }:
let
  inherit (pkgs) lib;
in
harness: enable: trustedProjects:
import ../../home/h82/agents/quality-hooks.nix {
  inherit pkgs lib harness;
  config.my.agentHooks = {
    inherit trustedProjects;
    stop = true;
    ${harness} = {
      inherit enable;
      postEdit = true;
      preShell = true;
      freezeTests = true;
    };
  };
}
