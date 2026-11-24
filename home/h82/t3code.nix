/*
  T3 Code, one artifact per trait: my.t3.cli.enable installs the
  headless `t3` CLI and my.t3.desktop.enable the desktop app. Its Claude
  and Codex sessions run the flake's own claude and codex with their
  user-level settings, so nothing here adds a copy of either. OpenCode and Pi
  run the flake's own builds through the user profile. The T3 Code
  declared settings are merged into its
  own settings files on activation.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.t3;
  darwin = config.my.kind == "darwin";

  agentTools = import ../../packages/agent-tools.nix { inherit pkgs; };
  merger = "${agentTools.agentSettings}/bin/agent-settings";
  t3 = cfg.cli.enable || cfg.desktop.enable;
  profileDirectory = config.home.profileDirectory or "${config.home.homeDirectory}/.nix-profile";
  hiddenPiModelArgs = lib.escapeShellArgs (
    lib.concatMap (model: [
      "--hide-model"
      model
    ]) (import ./agents/pi-hidden-models.nix)
  );

  retiredAntigravityBinary = "${profileDirectory}/bin/agy_acp_server.par";

  # OpenCode has no launch option for extra instructions, and a global
  # `instructions` entry would reach sessions outside T3 Code. T3 Code starts
  # its server with OPENCODE_CONFIG_CONTENT taken from the instance's
  # environment, so the T3-only branch is listed there, which only T3 sessions
  # see. The merge replaces this one entry by name and keeps the instance's
  # other environment entries.
  opencodeInstructions = {
    path = [
      "providerInstances"
      "opencode"
      "environment"
    ];
    key = "name";
    value = {
      name = "OPENCODE_CONFIG_CONTENT";
      value = builtins.toJSON {
        instructions = [ "${config.home.homeDirectory}/.t3/userdata/instructions/opencode.md" ];
      };
      sensitive = false;
    };
  };

  # Launch additions share the native account homes and baseline instructions.
  composer = pkgs.writeScriptBin "t3-instructions" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../../scripts/t3-instructions.py
  );
  renderer = import ../../packages/text-template.nix { inherit pkgs; };
  harnesses = [
    "claude"
    "codex"
    "pi"
    "opencode"
  ];
  additions = pkgs.runCommand "t3-instruction-additions" { } ''
    mkdir -p "$out"
    ${lib.concatMapStrings (harness: ''
      printf '%s' ${
        lib.escapeShellArg (
          builtins.toJSON ({ t3 = true; } // lib.genAttrs harnesses (name: name == harness))
        )
      } > context.json
      ${renderer}/bin/text-template ${./agents/instructions/instructions.md.tmpl} context.json > "$out/${harness}.md"
    '') harnesses}
  '';
  settings = {
    addProjectBaseDirectory = "~/src";
    # "Clone into host folders": clones land in <host>/<owner>/<repo> under
    # addProjectBaseDirectory, the way ghq lays them out.
    ghqCloneLayout = true;
    autoResumeLimitedThreads = true;
    branchNamingMode = "semantic";
    defaultAutoPull = true;
    # New threads start in a new worktree. A value here outranks every
    # repository's t3.json; only a per-project override in the app wins.
    defaultThreadEnvMode = "worktree";
    defaultRuntimeMode = "full-access";
    sidebarAutoSettleOnMerge = true;
    sidebarAutoSettleAfterDays = 3;
    sidebarAutoSettleKeepPullRequests = true;
    enableAgentDeviceAccess = true;
    enableDeviceSupport = true;
    linkedEnvironmentsEnabled = true;
    promptSuggestionsEnabled = true;
    providerInstances = {
      claudeAgent = {
        driver = "claudeAgent";
        enabled = true;
        config.idleCompaction = "beforeCacheExpires";
      };
      # The codex on PATH is the packaged wrapper, so no binaryPath is needed.
      # Codex reads the baseline from ~/.codex/AGENTS.md. The composer adds
      # T3 context through its native developer-instructions launch option.
      #
      # T3 Code gives a Codex instance its own home only when its config names
      # one: a homePath, a shadowHomePath, or the "managed" setupMode. The
      # merge keeps every field not declared here, so one set in the app would
      # survive every apply. An empty homePath would still let a CODEX_HOME in
      # the instance's own environment, which the merge also keeps, choose the
      # home, because T3 Code sets CODEX_HOME only for a nonempty homePath.
      # Declaring homePath as ~/.codex, which T3 Code expands, and the
      # non-managed "existing" setupMode keeps the sessions on ~/.codex, where
      # the plugin sync and home/h82/agents/skills.nix install. shadowHomePath stays
      # undeclared: a shadow home shares skills and plugins with ~/.codex.
      codex = {
        driver = "codex";
        enabled = true;
        config = {
          homePath = "~/.codex";
          setupMode = "existing";
        };
      };
      # T3 Code recreates an enabled Grok instance from session history when
      # the default instance is absent. Keep an explicit disable here.
      grok = {
        driver = "grok";
        enabled = false;
      };
      # The managed build in the shared user profile, not whichever opencode
      # comes first on PATH.
      opencode = {
        driver = "opencode";
        enabled = true;
        config.enabled = true;
        config.binaryPath = "${profileDirectory}/bin/opencode";
      };
      # Pi resolves to the restored native wrapper in the shared user profile.
      pi = {
        driver = "pi";
        enabled = true;
        config.enabled = true;
        config.binaryPath = "${profileDirectory}/bin/pi";
      };
    };
    snoozeLimitedThreads = true;
    sourceControlWritingStyle = {
      mode = "conventional_commits";
      customInstructions = "";
    };
    threadTitleInstructions = ''
      Write the title as a Conventional Commit subject: type(scope): description or type: description.
      Use a lowercase type and a short imperative description of the thread's goal, with no trailing period.
      Examples: fix(auth): refresh expired tokens; chore: update dependencies.
      When regenerating a title, correct the format even if the previous title names the right subject.
    '';
    storageCleanup = {
      browserArtifactsAfterDays = 8;
      logsAfterDays = 8;
      worktreeAfterDays = 5;
      worktreeOnDelete = true;
      worktreeOnMerge = true;
      worktreeSettledAfterDays = 1;
      worktreeUnchanged = true;
    };
  };

  # Keys that used to be declared. agent-settings removes these: the merge only
  # assigns, so dropping a key from settings alone would leave its last
  # written value on every machine forever. Move it here instead, and delete
  # the entry once every host has rebuilt past it.
  retiredKeys = [
    # Review guides follow the shared text generation selection.
    "reviewGuideModelSelection"
  ];

  # Nested entries previously written by this module.
  retiredPaths = [
    {
      path = [
        "providerInstances"
        "antigravity"
        "config"
      ];
      key = "binaryPath";
      value = retiredAntigravityBinary;
    }
    {
      path = [
        "providerInstances"
        "grok"
      ];
      key = "config";
    }
    {
      path = [
        "providerInstances"
        "grok"
      ];
      key = "environment";
    }
    {
      path = [ "providers" ];
      key = "grok";
      prune = true;
    }
    {
      path = [ "providerInstances" ];
      key = "omp";
    }
    {
      path = [ "providers" ];
      key = "omp";
      prune = true;
    }
    {
      path = [ "providerModelPreferences" ];
      key = "omp";
      prune = true;
    }
    {
      path = [ "providerInstances" ];
      key = "omp-codex";
    }
  ];

  # providers is the retired per-kind block T3 Code moves into
  # providerInstances on load, but only into an instance that does not exist
  # yet. The instances declared above would make it skip theirs and drop the
  # user's fields, so the merge moves those kinds first, the same way, and
  # leaves the others for T3 Code.
  instanceMigration = {
    from = "providers";
    to = "providerInstances";
    kinds = lib.remove "grok" (lib.attrNames settings.providerInstances);
    retireAntigravity = {
      profileBinary = retiredAntigravityBinary;
      registryCommand = "${config.home.homeDirectory}/.local/share/dotfiles/antigravity-acp/bin/antigravity-acp";
      instructions = "${config.home.homeDirectory}/.t3/userdata/instructions/antigravity.md";
    };
  };

  # T3 Code writes a model selection whole, with options that belong to the
  # chosen model, so a selection is owned rather than merged leaf by leaf:
  # a leaf merge would keep a previous model's options.
  modelSelections = {
    defaultModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-opus-5-5";
      options = [
        {
          id = "effort";
          value = "medium";
        }
      ];
    };
    # Another provider (Synthetic through Pi), because T3 Code falls back only
    # when the default model's usage window is exhausted and the fallback
    # model's is not. "high" is the highest thinking level Pi offers for it.
    fallbackModelSelection = {
      instanceId = "pi";
      model = "synthetic/hf:zai-org/GLM-5.3-Flash";
      options = [
        {
          id = "thinking";
          value = "high";
        }
      ];
    };
    textGenerationModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-haiku-5-5";
    };
  };

  clientSettings = {
    fontFamilySans = "Pretendard Variable";
    fontFamilyCode = "Jetendard";
    fontFamilyTerminal = "Jetendard";
    notificationMode = "notifications";
    inAppNotificationsEnabled = true;
    sidebarWorkingShelfEnabled = true;
    snapShotEnabled = true;
  };

  # The app and the CLI rewrite both files at runtime, so the keys are merged
  # in rather than owned by a store symlink. An object T3 Code may extend is
  # declared leaf by leaf, as home/h82/dev/vscodium.nix does.
  leaves = import ./settings-leaves.nix { inherit lib; };

  declaration = values: {
    remove = [ ];
    set = lib.filterAttrs (_: value: !lib.isAttrs value) values;
    setPaths = leaves (lib.filterAttrs (_: lib.isAttrs) values);
    own = { };
  };
  merges = {
    t3codeSettings = {
      file = "settings.json";
      ledger = "t3code-settings-ownership.json";
      declared = pkgs.writeText "t3code-declared-settings.json" (
        builtins.toJSON (
          (declaration settings)
          // {
            own = modelSelections;
            remove = retiredKeys;
            removePaths = retiredPaths;
            upsertPaths = [ opencodeInstructions ];
            migrateInstances = instanceMigration;
          }
        )
      );
    };
    t3codeClientSettings = {
      file = "client-settings.json";
      declared = pkgs.writeText "t3code-declared-client-settings.json" (
        builtins.toJSON (declaration clientSettings)
      );
    };
  };
in
{
  home.packages =
    lib.optionals cfg.cli.enable [ (import ../../packages/t3code-cli.nix { inherit pkgs; }) ]
    ++ lib.optionals (cfg.desktop.enable) [
      (import ../../packages/t3code.nix { inherit pkgs; })
    ];

  # Home Manager copies the macOS app bundle into ~/Applications writable, so
  # the app's own updater could move it off the release pin. The Linux wrapper
  # turns the updater off with this variable; on macOS a login agent sets it
  # for every app launched from Finder or the Dock.
  launchd.agents.t3code-disable-auto-update = lib.mkIf (cfg.desktop.enable && darwin) {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/launchctl"
        "setenv"
        "T3CODE_DISABLE_AUTO_UPDATE"
        "1"
      ];
      RunAtLoad = true;
    };
  };

  # The desktop app and the CLI share ~/.t3. One settings entry per file, so a
  # refusal on one does not hide the other. Ordered after installPackages, as
  # the Claude Code merge in agents/claude.nix is, so a refusal cannot strand
  # linkGeneration. `run` leaves the files alone on a dry run.

  home.activation = lib.mkIf t3 (
    {
      t3codeInstructions =
        lib.hm.dag.entryAfter
          [ "t3codeSettings" "t3codeClientSettings" "agentInstructions" "codexSettings" ]
          ''
            if [[ ! -v DRY_RUN ]]; then
              install -d -m 700 "${config.home.homeDirectory}/.t3/userdata/instructions"
              for harness in ${toString harnesses}; do
                install -m 600 "${additions}/$harness.md" "${config.home.homeDirectory}/.t3/userdata/instructions/$harness.md"
              done
              ${composer}/bin/t3-instructions --destination ${lib.escapeShellArg config.home.homeDirectory} ${hiddenPiModelArgs}
            fi
          '';
    }
    // lib.mapAttrs (
      _: merge:
      lib.hm.dag.entryAfter [ "installPackages" ] ''
        run ${merger} \
          --label 'T3 Code' \
          --settings ${config.home.homeDirectory}/.t3/userdata/${merge.file} \
          --declared ${merge.declared} ${
            lib.optionalString (
              merge ? ledger
            ) "\\\n          --ledger ${config.home.homeDirectory}/.t3/userdata/${merge.ledger}"
          }
      ''
    ) merges
  );
}
