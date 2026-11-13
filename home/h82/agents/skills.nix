{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Each root is a directory one harness reads skills from. Claude Code reads
  # ~/.claude/skills. The Antigravity CLI reads
  # ~/.gemini/antigravity-cli/skills, and T3 Code builds its Antigravity skill
  # menu from that directory and ~/.gemini/config/skills, which agy 1.5.8
  # makes one directory by replacing the former with a link to the latter.
  # Codex reads ~/.codex/skills; not ~/.agents/skills, which no harness here
  # owns. A harness lists a skill it reaches through more than one root once,
  # because every root's link resolves to the same store directory.
  antigravityRoot = ".gemini/antigravity-cli/skills";
  roots = [
    ".claude/skills"
    antigravityRoot
    ".codex/skills"
    ".grok/skills"
    ".pi/agent/skills"
  ];

  plugin = import ./plugin-skills.nix { inherit lib pkgs; };

  # Plugin skills are linked into the Antigravity root only, which is where
  # T3 Code's skill menu finds them. The Antigravity ACP runtime also receives
  # them as one store directory, for Compound Engineering run homes, and the
  # CLI gets them from its native plugin install.
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

  options.my.antigravitySkillNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    readOnly = true;
    default = lib.attrNames config.my.agentSkills;
    description = ''
      Shared skill names the Antigravity ACP wrapper links into Compound
      Engineering run homes. Plugin skills reach those homes separately.
    '';
  };

  options.my.antigravityRootSkillNames = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    internal = true;
    readOnly = true;
    default = lib.attrNames (config.my.agentSkills // pluginSkills);
    description = "All shared and plugin skill names declared in the Antigravity root.";
  };

  options.my.antigravityPluginSkills = lib.mkOption {
    type = lib.types.package;
    internal = true;
    readOnly = true;
    default = plugin.directory pluginSkills;
    description = ''
      One store directory holding a link per plugin skill of every pinned
      plugin, named by skill. The Antigravity ACP wrapper hands it to the
      runtime as its plugin skills directory.
    '';
  };

  # One link per root and skill, to the skill directory itself: Codex skips a
  # SKILL.md that is a symlink, so the files inside must not be linked one by
  # one with `recursive = true`.
  #
  # The seq makes a name shared by a plugin skill and a contributed skill stop
  # every evaluation, not only one that reads the plugin skills directory.
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
