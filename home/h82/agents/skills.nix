{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Each root is a directory one harness reads skills from. Claude Code reads
  # ~/.claude/skills. The Antigravity CLI reads
  # ~/.gemini/antigravity-cli/skills, which agy links to ~/.gemini/config/skills.
  # Codex reads ~/.codex/skills; not ~/.agents/skills, which no harness here
  # owns. A harness lists a skill it reaches through more than one root once,
  # because every root's link resolves to the same store directory.
  antigravityRoot = ".gemini/antigravity-cli/skills";
  roots = [
    ".claude/skills"
    antigravityRoot
    ".codex/skills"
    ".pi/agent/skills"
  ];

  plugin = import ./plugin-skills.nix { inherit lib; };

  pluginSkills = plugin.skills {
    sources = config.my.agentPluginSources;
    sharedNames = lib.attrNames config.my.agentSkills;
  };

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

  options.my.antigravityRootSkillNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    readOnly = true;
    default = lib.attrNames (config.my.agentSkills // pluginSkills);
    description = "All shared and plugin skill names declared in the Antigravity root.";
  };

  # One link per root and skill, to the skill directory itself: Codex skips a
  # SKILL.md that is a symlink, so the files inside must not be linked one by
  # one with `recursive = true`.
  #
  # The seq makes a name shared by a plugin skill and a contributed skill stop
  # every evaluation.
  config.home.file = builtins.seq pluginSkills (
    lib.listToAttrs (
      lib.concatMap (
        root:
        lib.mapAttrsToList (
          name: source: lib.nameValuePair "${root}/${name}" { inherit source; }
        ) config.my.agentSkills
      ) roots
      ++ lib.mapAttrsToList (
        name: source: lib.nameValuePair "${antigravityRoot}/${name}" { inherit source; }
      ) pluginSkills
    )
  );
}
