{ pkgs, ... }:
let
  intent = import ../../../packages/tanstack-intent.nix { inherit pkgs; };
in
{
  home.packages = [ intent ];
  my.agentSkills.project-skills = pkgs.writeTextDir "SKILL.md" (
    builtins.replaceStrings [ "@intent@" "@jq@" ] [ (pkgs.lib.getExe intent) (pkgs.lib.getExe pkgs.jq) ]
      (builtins.readFile ./skills/project-skills/SKILL.md)
  );
}
