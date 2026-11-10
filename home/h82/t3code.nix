/*
  T3 Code nightly, one artifact per trait: my.t3.cli.enable installs the
  headless `t3` CLI and my.t3.desktop.enable the desktop app. Its Claude
  and Codex sessions run the flake's own claude and codex with their
  user-level settings, so nothing here adds a copy of either. The T3 Code
  settings that differ from the pinned nightly's defaults are merged into its
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

  omp = import ../../packages/omp.nix { inherit pkgs; };
  catalogs = import ./agents/omp-model-catalogs.nix;
  ompRoles = import ./agents/omp-roles.nix;
  ompScope = pkgs.writeText "omp-t3-OMP.json" (
    builtins.toJSON {
      enabledModels = ompPatterns;
      inherit (catalogs) disabledProviders;
      ask.enabled = false;
      todo.reminders = false;
      inherit (ompRoles)
        defaultThinkingLevel
        github
        modelRoles
        task
        ;
      skills.customDirectories = (config.my.omp or { }).skillDirectories or [ ];
    }
  );
  ompPatterns = catalogs.patterns;

  # The runtime of the Antigravity ACP release the pinned T3 Code embeds,
  # which can trail the newest one that packages/antigravity-acp-path.nix puts
  # on PATH. T3 Code resolves an explicit binaryPath before its managed
  # download, finds localharness_external beside it, and sets the child's
  # SSL_CERT_FILE itself on Linux, so the instance needs no wrapper.
  antigravityAcp = import ../../packages/antigravity-acp.nix {
    inherit pkgs;
    pins = (builtins.fromJSON (builtins.readFile ../../packages/t3code-release.json)).antigravity;
  };
  openrouterSelectors = map (row: "openrouter/${row.id}") catalogs.openrouter.data;
  apiSelectors = lib.unique (
    map (row: "synthetic/${row.id}") catalogs.synthetic.data ++ openrouterSelectors
  );
  ompInstances.omp = {
    driver = "acpRegistry";
    displayName = "OMP";
    enabled = true;
    config = {
      source = "local";
      commandPath = "${omp}/bin/omp";
      commandArgs = [
        "--mode"
        "acp"
        "--config"
        ompScope
        "--models"
        (lib.concatStringsSep "," ompPatterns)
        # --models otherwise falls back to the first available API model
        # when the configured Synthetic default has no authentication.
        "--model"
        "synthetic/hf:moonshotai/Kimi-K3"
        "--thinking"
        "high"
      ];
      customModels = apiSelectors;
    };
  };

  # The settings that differ from the pinned T3 Code's schema defaults; a
  # value left at its default follows T3 Code when that default changes. Each
  # declared provider instance states `enabled`, even where it equals the
  # default: claudeAgent's and codex's do, since T3 Code turns those instances
  # on. A cleanup that drops default-valued settings must keep it, or the instance
  # would go back to following T3 Code's default. App state (onboarding marks,
  # folded panels, favorites, and every provider instance field not declared
  # here) stays the app's. T3 Code leaves its built-in Pi
  # instance off until it is enabled, so none shows up on its own.
  settings = {
    addProjectBaseDirectory = "~/src";
    autoResumeLimitedThreads = true;
    branchNamingMode = "semantic";
    defaultAutoPull = true;
    # New threads start in a new worktree. A value here outranks every
    # repository's t3.json; only a per-project override in the app wins.
    defaultThreadEnvMode = "worktree";
    enableAgentDeviceAccess = true;
    enableDeviceSupport = true;
    providerInstances = {
      antigravity = {
        driver = "antigravity";
        enabled = true;
        config.binaryPath = "${antigravityAcp}/libexec/antigravity-acp/agy_acp_server.par";
      };
      claudeAgent = {
        driver = "claudeAgent";
        enabled = true;
        config.launchArgs = "";
      };
      # The codex on PATH is the packaged wrapper, so no binaryPath is needed.
      # Codex reads the instructions from ~/.codex/AGENTS.md, so the launch
      # arguments an earlier generation wrote, which carried the old
      # instructions, are overwritten with nothing.
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
          launchArgs = "";
          setupMode = "existing";
        };
      };
      # The Grok Build CLI is installed by home/h82/agents/grok.nix.
      grok = {
        driver = "grok";
        enabled = true;
      };
      # OpenCode is gone, but the merge keeps undeclared fields, so this stays
      # declared to turn off the instance an earlier generation enabled.
      opencode = {
        driver = "opencode";
        enabled = false;
      };
      omp = removeAttrs ompInstances.omp [ "config" ];
      # Keep the instance and its state, but stop offering it for new work.
      pi = {
        driver = "pi";
        enabled = false;
      };
    };
    snoozeLimitedThreads = true;
    sourceControlWritingStyle.mode = "conventional_commits";
    storageCleanup = {
      browserArtifactsAfterDays = 8;
      logsAfterDays = 8;
      worktreeAfterDays = 8;
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
      key = "omp-codex";
    }
    {
      path = [ "providerModelPreferences" ];
      key = "opencode";
      prune = true;
    }
  ];

  # T3 Code synthesizes a built-in `default` entry for ACP Registry instances
  # before discovery completes; prefixEntries hides it without overwriting
  # other OMP models the user hid in the app.
  hiddenModels = [
    {
      path = [
        "providerModelPreferences"
        "omp"
        "hiddenModels"
      ];
      prefix = "default";
      value = "default";
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
      instanceId = "claudeAgent";
      model = "claude-opus-5-5";
      options = [
        {
          id = "effort";
          value = "medium";
        }
      ];
    };
    textGenerationModelSelection = {
      instanceId = "claudeAgent";
      model = "claude-haiku-5-5";
      options = [ ];
    };
  };

  clientSettings.fontFamilyCode = "JetBrains Mono";

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
          prefixEntries = hiddenModels;
          migrateInstances = instanceMigration;
          # Arrays are whole values. The existing ownership ledger replaces
          # only these config keys and preserves app-owned environment/auth.
          ownEntries = lib.mapAttrsToList (id: instance: {
            path = [
              "providerInstances"
              id
              "config"
            ];
            entries = instance.config;
          }) ompInstances;
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
  # the app's own updater could move it off the nightly pin. The Linux wrapper
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
    lib.mapAttrs (
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
