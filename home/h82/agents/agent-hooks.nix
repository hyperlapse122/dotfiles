{ lib, ... }:
let
  inherit (lib)
    genAttrs
    mkEnableOption
    ;
in
{
  options.my.agentHooks = genAttrs [ "claude" "codex" "pi" "opencode" ] (_: {
    enable = mkEnableOption "native agent quality hooks" // {
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
