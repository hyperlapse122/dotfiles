{
  config,
  lib,
  ...
}:
let
  roots = [
    ".claude/skills"
    ".codex/skills"
    ".pi/agent/skills"
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

  # One link per root and skill, to the skill directory itself: Codex skips a
  # SKILL.md that is a symlink, so the files inside must not be linked one by
  # one with `recursive = true`.
  config.home.file = lib.listToAttrs (
    lib.concatMap (
      root:
      lib.mapAttrsToList (
        name: source: lib.nameValuePair "${root}/${name}" { inherit source; }
      ) config.my.agentSkills
    ) roots
  );
}
