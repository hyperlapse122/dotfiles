{
  config,
  pkgs,
  lib,
  ...
}:
let
  roots = [
    ".claude/skills"
    ".pi/agent/skills"
    ".config/opencode/skills"
  ];
in
{
  options.my.agentSkillRoots = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    readOnly = true;
    default = roots;
    description = ''
      Every harness's skill root, relative to the home directory.
    '';
  };

  options.my.agentSkills = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    internal = true;
    default = { };
    description = ''
      Skill directories by skill name, linked into every harness's skill root.
    '';
  };

  options.my.agentSkillReferences = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.path);
    internal = true;
    default = { };
    description = "References grouped by domain and guide name.";
  };

  config.my.agentSkills = lib.mapAttrs (
    domain: references:
    pkgs.runCommand domain { } ''
      mkdir -p "$out/references"
      cp -r --no-preserve=mode ${./skills + "/${domain}"}/. "$out/"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: source: ''
          mkdir -p "$out/references/${name}"
          cp -r --no-preserve=mode ${source}/. "$out/references/${name}/"
          mv "$out/references/${name}/SKILL.md" "$out/references/${name}/${name}.md"
        '') references
      )}
    ''
  ) config.my.agentSkillReferences;

  # One link per root and skill, to the skill directory itself: a harness that
  # skips a symlinked SKILL.md needs the files inside linked as one directory,
  # not one by one with `recursive = true`.
  config.home.file = lib.listToAttrs (
    lib.concatMap (
      root:
      lib.mapAttrsToList (
        name: source: lib.nameValuePair "${root}/${name}" { inherit source; }
      ) config.my.agentSkills
    ) roots
  );
}
