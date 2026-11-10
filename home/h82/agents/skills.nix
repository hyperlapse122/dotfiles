{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # Each root is a directory one harness reads skills from. Claude Code reads
  # ~/.claude/skills. The Antigravity CLI and T3 Code's Antigravity instances
  # read ~/.gemini/antigravity-cli/skills; not ~/.gemini/config/skills, which
  # the CLI lists twice. Codex reads
  # ~/.codex/skills; not ~/.agents/skills, which no harness here owns. Codex
  # lists a skill it reaches through more than one root once, because every
  # root's link resolves to the same store directory.
  antigravityRoot = ".gemini/antigravity-cli/skills";
  roots = [
    ".claude/skills"
    antigravityRoot
    ".codex/skills"
    ".grok/skills"
    ".pi/agent/skills"
  ];

  # Native plugins own CE skills. Check for collisions with contributed skills
  # before linking them into a harness root.
  ceSkillsDir = "${inputs.compound-engineering-plugin}/skills";
  ceSkills = lib.filterAttrs (
    name: type: type == "directory" && builtins.pathExists "${ceSkillsDir}/${name}/SKILL.md"
  ) (builtins.readDir ceSkillsDir);
  ceSkillNames = lib.attrNames ceSkills;

  # Two skills of one name in one root would silently keep only one of them.
  collisions = lib.intersectLists ceSkillNames (lib.attrNames config.my.agentSkills);

in
{
  options.my.agentSkills = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    internal = true;
    default = { };
    description = ''
      Skill directories by skill name, linked into every harness's skill root.
    '';
  };

  options.my.antigravitySkillNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    readOnly = true;
    default = lib.attrNames config.my.agentSkills;
    description = ''
      Every contributed skill linked into ~/${antigravityRoot}. The native
      plugin supplies Compound Engineering. The Antigravity ACP wrapper links
      these into Compound Engineering run homes.
    '';
  };

  # One link per root and skill, to the skill directory itself: Codex skips a
  # SKILL.md that is a symlink, so the files inside must not be linked one by
  # one with `recursive = true`.
  config.home.file =
    lib.throwIf (collisions != [ ])
      "skills: Compound Engineering and contributed skills share the name(s) ${lib.concatStringsSep ", " collisions} in ~/${antigravityRoot}"
      (
        lib.listToAttrs (
          lib.concatMap (
            root:
            lib.mapAttrsToList (
              name: source: lib.nameValuePair "${root}/${name}" { inherit source; }
            ) config.my.agentSkills
          ) roots
        )

      );
}
