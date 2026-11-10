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
  ];

  # The ACP runtime loads no plugins, so Antigravity gets the pinned Compound
  # Engineering skills as plain skill links beside the contributed ones. The
  # other harnesses install the plugin itself (agent-plugins.nix).
  ceSkillsDir = "${inputs.compound-engineering-plugin}/skills";
  ceSkills = lib.filterAttrs (
    name: type: type == "directory" && builtins.pathExists "${ceSkillsDir}/${name}/SKILL.md"
  ) (builtins.readDir ceSkillsDir);
  ceSkillNames = lib.attrNames ceSkills;

  # Two skills of one name in one root would silently keep only one of them.
  collisions = lib.intersectLists ceSkillNames (lib.attrNames config.my.agentSkills);

  antigravityCli = import ../../../packages/antigravity-cli.nix { inherit pkgs; };
  home = config.home.homeDirectory;
  retiredPlugins = "${home}/.gemini/config/plugins";

  # The retired t3code-antigravity-link left unmanaged links from this root
  # into the plugin copy `agy plugin install` made. Home Manager refuses to
  # replace a foreign file with a declared skill, so they go before
  # checkLinkTargets. Nothing here may fail the apply.
  retireScript = ''
    skillRoot=${lib.escapeShellArg "${home}/${antigravityRoot}"}
    retiredPlugins=${lib.escapeShellArg retiredPlugins}
    if [[ -d $skillRoot ]]; then
      for entry in "$skillRoot"/* "$skillRoot"/.[!.]*; do
        [[ -e $entry || -L $entry ]] || continue
        if [[ -L $entry ]]; then
          target=$(readlink "$entry") || target=
          case "$target" in
            "$retiredPlugins"/*)
              echo "antigravitySkillsRetire: removing retired link $entry -> $target"
              run rm -f "$entry" || echo "antigravitySkillsRetire: could not remove $entry" >&2
              continue
              ;;
            /nix/store/*) continue ;;
          esac
        fi
        echo "antigravitySkillsRetire: keeping $entry, which this configuration did not create" >&2
      done
    fi
    if [[ -e $retiredPlugins/compound-engineering || -L $retiredPlugins/compound-engineering ]]; then
      if [[ -v DRY_RUN ]]; then
        echo "antigravitySkillsRetire: would run agy plugin uninstall compound-engineering"
      elif ${antigravityCli}/bin/agy plugin uninstall compound-engineering; then
        echo "antigravitySkillsRetire: uninstalled the retired compound-engineering Antigravity plugin"
      else
        echo "antigravitySkillsRetire: agy plugin uninstall compound-engineering failed with status $?; remove $retiredPlugins/compound-engineering by hand" >&2
      fi
    fi
  '';
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
    default = lib.attrNames config.my.agentSkills ++ ceSkillNames;
    description = ''
      Every skill linked into ~/${antigravityRoot}: the contributed skills and
      the pinned Compound Engineering ones. The Antigravity ACP wrapper links
      these into Compound Engineering run homes.
    '';
  };

  config.home.activation.antigravitySkillsRetire = lib.hm.dag.entryBefore [
    "checkLinkTargets"
  ] retireScript;

  # One link per root and skill, to the skill directory itself: Codex skips a
  # SKILL.md that is a symlink, so the files inside must not be linked one by
  # one with `recursive = true`.
  config.home.file =
    lib.throwIf (collisions != [ ])
      "skills: Compound Engineering and contributed skills share the name(s) ${lib.concatStringsSep ", " collisions} in ~/${antigravityRoot}"
      (
        {
          # Own the whole native root so removed contributed skills stop loading.
          # OMP's separate managed-skills history remains inactive and untouched.
          ".omp/agent/skills".source = pkgs.linkFarm "omp-contributed-skills" (
            lib.mapAttrsToList (name: path: { inherit name path; }) config.my.agentSkills
          );
        }
        // lib.listToAttrs (
          lib.concatMap (
            root:
            lib.mapAttrsToList (
              name: source: lib.nameValuePair "${root}/${name}" { inherit source; }
            ) config.my.agentSkills
          ) roots
        )
        // lib.listToAttrs (
          map (
            name: lib.nameValuePair "${antigravityRoot}/${name}" { source = "${ceSkillsDir}/${name}"; }
          ) ceSkillNames
        )
      );
}
