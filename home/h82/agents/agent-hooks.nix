{ lib, ... }:
let
  inherit (lib)
    genAttrs
    mkEnableOption
    mkOption
    types
    ;
in
{
  options.my.agentHooks = {
    trustedProjects = mkOption {
      type = types.listOf (types.strMatching "/[^\n]+");
      default = [ ];
      description = ''
        Exact canonical Git checkout roots the owner authorizes to execute
        agent-check with the native hook process's host privileges.
      '';
    };
    stop = mkEnableOption "a final agent-check with one corrective continuation";
  }
  // genAttrs [ "claude" "codex" "pi" "opencode" ] (_: {
    enable = mkEnableOption "native agent quality hooks" // {
      default = true;
    };
    postEdit = mkEnableOption "agent-check after native edits" // {
      default = true;
    };
    preShell = mkEnableOption "feedback for Git commit hook bypasses" // {
      default = true;
    };
    freezeTests = mkEnableOption "native test edit protection when .agents/freeze-tests exists" // {
      default = true;
    };
  });
}
