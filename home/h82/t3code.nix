/*
  T3 Code, one artifact per trait: my.t3.cli.enable installs the
  headless `t3` CLI and my.t3.desktop.enable the desktop app. Its Claude
  and Codex sessions run the flake's own claude and codex with their
  user-level settings, so nothing here adds a copy of either. The T3 Code
  declared settings are merged into its
  own settings files on activation.

  The desktop app runs on NixOS and macOS. A non-NixOS Linux host that enables
  it fails the assertion below rather than a build.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.t3;
  nixos = config.my.kind == "nixos";
  darwin = config.my.kind == "darwin";
  desktopSupported = nixos || darwin;

  agentTools = import ../../packages/agent-tools.nix { inherit pkgs; };
  merger = "${agentTools.agentSettings}/bin/agent-settings";
  t3 = cfg.cli.enable || cfg.desktop.enable;
  profileDirectory = config.home.profileDirectory or "${config.home.homeDirectory}/.nix-profile";

  # T3 Code keeps an instance's home under the sha256 of its id, and the
  # runtime stores its Google sign-in in that home.
  antigravityInstanceId = "antigravity";
  antigravityInstanceToken = "${config.home.homeDirectory}/.t3/userdata/providers/${antigravityInstanceId}/${builtins.hashString "sha256" antigravityInstanceId}/antigravity-acp/acp_token.json";

  # Launch additions share the native account homes and baseline instructions.
  composer = pkgs.writeScriptBin "t3-instructions" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../../scripts/t3-instructions.py
  );
  grokAdapter = import ../../packages/t3-grok-instructions.nix { inherit pkgs; };
  renderer = import ../../packages/text-template.nix { inherit pkgs; };
  additions = pkgs.runCommand "t3-instruction-additions" { } ''
    mkdir -p "$out"
    for harness in claude codex pi antigravity grok; do
      printf '{"t3":true,"claude":%s,"codex":%s,"pi":%s,"antigravity":%s,"grok":%s}' \
        "$([ "$harness" = claude ] && echo true || echo false)" \
        "$([ "$harness" = codex ] && echo true || echo false)" \
        "$([ "$harness" = pi ] && echo true || echo false)" \
        "$([ "$harness" = antigravity ] && echo true || echo false)" \
        "$([ "$harness" = grok ] && echo true || echo false)" > context.json
      ${renderer}/bin/text-template ${./agents/instructions/instructions.md.tmpl} context.json > "$out/$harness.md"
    done
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
      # The Grok Build CLI is installed by home/h82/agents/grok.nix.
      grok = {
        driver = "grok";
        enabled = true;
        config.binaryPath = "${grokAdapter}/bin/t3-grok-instructions";
      };
      # OpenCode is gone, but the merge keeps undeclared fields, so this stays
      # declared to turn off the instance an earlier generation enabled.
      opencode = {
        driver = "opencode";
        enabled = false;
      };
      # Pi resolves to the restored native wrapper in the shared user profile.
      pi = {
        driver = "pi";
        enabled = true;
        config.enabled = true;
        config.binaryPath = "${profileDirectory}/bin/pi";
      };
      # T3 Code resolves the real path of binaryPath and requires the runtime's
      # localharness_external beside it, which the rebuilt runtime provides.
      # The leaves are declared one by one, so keys the owner sets under the
      # instance survive.
      ${antigravityInstanceId} = {
        driver = "antigravity";
        enabled = true;
        config.binaryPath = "${profileDirectory}/bin/agy_acp_server.par";
      };
    };
    snoozeLimitedThreads = true;
    sourceControlWritingStyle = {
      mode = "conventional_commits";
      customInstructions = "";
    };
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
  retiredKeys = [ ];

  # Nested entries that used to be declared, retired the same way. An earlier
  # generation hid OpenCode's text-generation alias here; prune drops the
  retiredPaths = [
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
    {
      path = [ "providerModelPreferences" ];
      key = "opencode";
      prune = true;
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
    kinds = lib.attrNames settings.providerInstances;
  };

  # T3 Code writes a model selection whole, with options that belong to the
  # chosen model, so a selection is owned rather than merged leaf by leaf:
  # a leaf merge would keep a previous model's options.
  modelSelections = {
    defaultModelSelection = {
      instanceId = "codex";
      model = "gpt-6.1-sol";
      options = [
        {
          id = "reasoningEffort";
          value = "xhigh";
        }
        {
          id = "serviceTier";
          value = "default";
        }
      ];
    };
    fallbackModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-opus-5-5";
    };
    textGenerationModelSelection = {
      instanceId = "codex";
      model = "gpt-6-luna";
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
  leaves =
    path: value:
    if lib.isAttrs value then
      lib.concatLists (lib.mapAttrsToList (key: leaves (path ++ [ key ])) value)
    else
      [ { inherit path value; } ];

  declaration =
    {
      values,
      owned ? { },
      remove ? [ ],
      removePaths ? [ ],
      prefixEntries ? [ ],
      migrateInstances ? null,
      ownEntries ? [ ],
    }:
    {
      inherit remove;
      set = lib.filterAttrs (_: value: !lib.isAttrs value) values;
      setPaths = leaves [ ] (lib.filterAttrs (_: lib.isAttrs) values);
      own = owned;
    }
    // lib.optionalAttrs (removePaths != [ ]) { inherit removePaths; }
    // lib.optionalAttrs (prefixEntries != [ ]) { inherit prefixEntries; }
    // lib.optionalAttrs (ownEntries != [ ]) { inherit ownEntries; }
    // lib.optionalAttrs (migrateInstances != null) { inherit migrateInstances; };
  merges = {
    t3codeSettings = {
      file = "settings.json";
      ledger = "t3code-settings-ownership.json";
      declared = pkgs.writeText "t3code-declared-settings.json" (
        builtins.toJSON (declaration {
          values = settings;
          owned = modelSelections;
          remove = retiredKeys;
          removePaths = retiredPaths;
          migrateInstances = instanceMigration;
        })
      );
    };
    t3codeClientSettings = {
      file = "client-settings.json";
      declared = pkgs.writeText "t3code-declared-client-settings.json" (
        builtins.toJSON (declaration {
          values = clientSettings;
        })
      );
    };
  };
in
{
  assertions = [
    {
      assertion = cfg.desktop.enable -> desktopSupported;
      message = "${config.my.hostName}: my.t3.desktop.enable: the T3 Code desktop app runs on NixOS and macOS only; enable my.t3.cli.enable on a non-NixOS Linux host.";
    }
  ];

  home.packages =
    lib.optionals cfg.cli.enable [ (import ../../packages/t3code-cli.nix { inherit pkgs; }) ]
    ++ lib.optionals (cfg.desktop.enable && desktopSupported) [
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
              for harness in claude codex pi antigravity grok; do
                install -m 600 "${additions}/$harness.md" "${config.home.homeDirectory}/.t3/userdata/instructions/$harness.md"
              done
              ${composer}/bin/t3-instructions --destination ${lib.escapeShellArg config.home.homeDirectory}
            fi
          '';
    }
    // {
      # The standard home's sign-in becomes a link to T3 Code's, so the Compound
      # Engineering run homes copy a token that exists and agent-usage reads
      # one. The target may not exist yet: a sign-in in T3 Code creates it. A
      # regular file is the owner's own sign-in and stays. Nothing here reads
      # or copies the token. On NixOS this runs only when a new Home Manager
      # generation activates.
      antigravitySignIn = lib.hm.dag.entryAfter [ "t3codeSettings" ] ''
        if [[ ! -v DRY_RUN ]]; then
          signInHome=${lib.escapeShellArg "${config.home.homeDirectory}/.gemini/antigravity-acp"}
          signInToken=$signInHome/acp_token.json
          [[ -d $signInHome ]] || install -d -m 700 "$signInHome"
          if [[ -L $signInToken || ! -e $signInToken ]]; then
            ln -sfn ${lib.escapeShellArg antigravityInstanceToken} "$signInToken"
          else
            echo "$signInToken holds its own Antigravity sign-in; it is kept and not shared with T3 Code." >&2
          fi
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
