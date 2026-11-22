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
        Exact canonical Git checkout roots opted in to native edit advisories
        and, if enabled, turn-end requests to run agent-check in the session.
      '';
    };
    stop = mkEnableOption "one turn-end request to run agent-check through the session's shell tool";
  }
  // genAttrs [ "claude" "codex" "pi" "opencode" ] (_: {
    enable = mkEnableOption "native agent quality hooks" // {
      default = true;
    };
    postEdit = mkEnableOption "local source scan advisories after native edits" // {
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
