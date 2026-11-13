{
  entries ? null,
  pkgs,
  self,
  fixtures ? [ ],
}:
let
  lib = pkgs.lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  userEntries = if entries == null then configurations.userEntries else entries;

  pluginSkills = import ../home/h82/agents/plugin-skills.nix { inherit lib pkgs; };
  esc = value: lib.escapeShellArg (toString value);

  # A second plugin joins the pinned ones through the same function the
  # module calls, so a later plugin needs no Antigravity-specific code.
  secondPlugin = {
    src = ./fixtures/plugins/second-plugin;
    plugin = "second-plugin";
  };
  agyPath = "/nix/store/0-fixture-agy/bin/agy";

  failsEvaluation = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  assertEntry =
    entry:
    let
      userConfig = entry.user;
      sources = userConfig.my.agentPluginSources;
      sharedNames = lib.attrNames userConfig.my.agentSkills;
      grown = sources // {
        second-plugin = secondPlugin;
      };
      realSkills = pluginSkills.skills {
        inherit sources sharedNames;
      };
      withSecond = pluginSkills.skills {
        sources = grown;
        inherit sharedNames;
      };
      withSecondDirectory = pluginSkills.directory withSecond;
      pluginsJson =
        sourceSet:
        pkgs.writeText "plugins.json" (
          builtins.toJSON (
            map (
              name:
              {
                plugin = sourceSet.${name}.plugin;
                source = toString (sourceSet.${name}.antigravityTree or sourceSet.${name}.src);
              }
              // lib.optionalAttrs (sourceSet.${name} ? antigravityTree) {
                pinned = toString sourceSet.${name}.src;
              }
            ) (lib.attrNames sourceSet)
          )
        );
      twinSources = {
        first = secondPlugin;
        second = secondPlugin;
      };
      sharedTargets = lib.concatMap (
        file:
        let
          prefix = ".gemini/antigravity-cli/skills/";
        in
        lib.optional (lib.hasPrefix prefix (file.target or "")) (lib.removePrefix prefix file.target)
      ) (lib.attrValues userConfig.home.file);
      pinnedSource = "${sources.compound-engineering.src}";
    in
    ''
      # The directory the wrapper receives holds one link per Compound
      # Engineering skill, and no name that ~/.gemini/antigravity-cli/skills
      # also receives.
      directory=${userConfig.my.antigravityPluginSkills}
      expected=$(find ${pinnedSource}/skills -mindepth 2 -maxdepth 2 -name SKILL.md \
        | awk -F/ '{print $(NF-1)}' | sort)
      actual=$(ls -1A "$directory" | sort)
      if [ -z "$expected" ]; then
        echo 'the pinned Compound Engineering source holds no skills on ${entry.name}' >&2
        failed=1
      fi
      if [ "$actual" != "$expected" ]; then
        echo 'the plugin skills directory must hold exactly the Compound Engineering skills on ${entry.name}' >&2
        failed=1
      fi
      for name in $actual; do
        if [ "$(readlink "$directory/$name")" != ${pinnedSource}/skills/$name ]; then
          echo "plugin skill $name must link to its source directory on ${entry.name}" >&2
          failed=1
        fi
      done
      printf '%s\n' ${lib.escapeShellArgs sharedTargets} | sed '/^$/d' | sort > shared-names
      if ! grep -q . shared-names; then
        echo '~/.gemini/antigravity-cli/skills receives no shared skills on ${entry.name}' >&2
        failed=1
      fi
      if [ -n "$(comm -12 shared-names - <<< "$actual")" ]; then
        echo 'a plugin skill is also linked into ~/.gemini/antigravity-cli/skills on ${entry.name}' >&2
        failed=1
      fi

      # The real activation step installs every pinned plugin.
      python3 ${./native-plugins.py} ${pkgs.writeText "agent-plugins.sh" userConfig.home.activation.nativeAgentPlugins.data} ${pluginsJson sources}

      # A second plugin reaches the directory and the Antigravity CLI install
      # without any change to either.
      if [ ${esc (lib.concatStringsSep " " (lib.attrNames withSecond))} != ${
        esc (
          lib.concatStringsSep " " (lib.sort lib.lessThan (lib.attrNames realSkills ++ [ "second-skill" ]))
        )
      } ]; then
        echo 'the second plugin must add exactly second-skill to the enumeration on ${entry.name}' >&2
        failed=1
      fi
      if [ ! -f ${withSecondDirectory}/second-skill/SKILL.md ]; then
        echo 'the plugin skills directory must hold second-skill on ${entry.name}' >&2
        failed=1
      fi
      python3 ${./native-plugins.py} ${
        pkgs.writeText "agy-install.sh" (
          pluginSkills.agyInstall {
            agy = agyPath;
            sources = grown;
          }
        )
      } ${pluginsJson grown} --agy-only

      # One skill name in two plugins, or in a plugin and the shared skills,
      # stops evaluation and names every owner.
      if [ ${
        lib.boolToString (
          failsEvaluation (
            pluginSkills.skills {
              sources = twinSources;
              sharedNames = [ ];
            }
          )
        )
      } != true ]; then
        echo 'two plugins sharing a skill name must fail evaluation on ${entry.name}' >&2
        failed=1
      fi
      if [ ${
        esc (
          lib.concatStringsSep "\n" (
            pluginSkills.problems {
              sources = twinSources;
              sharedNames = [ ];
            }
          )
        )
      } != ${esc "second-skill is provided by plugins first, second"} ]; then
        echo 'the duplicate skill error must name both plugins on ${entry.name}' >&2
        failed=1
      fi
      if [ ${
        lib.boolToString (
          failsEvaluation (
            pluginSkills.skills {
              sources = {
                second = secondPlugin;
              };
              sharedNames = [ "second-skill" ];
            }
          )
        )
      } != true ]; then
        echo 'a plugin skill named like a shared skill must fail evaluation on ${entry.name}' >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "antigravity-skills-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.python3
    ];
  }
  ''
    ${lib.optionalString (entries == null) configurations.userGuard}
    failed=0
    ${lib.concatMapStrings assertEntry userEntries}
    if [ "$failed" != "0" ]; then
      exit 1
    fi
    touch $out
  ''
