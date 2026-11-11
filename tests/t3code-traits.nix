/*
  Guard T3 package traits and execute the materialized settings activations.
  The existing activation harness checks repeat apply, dry runs, refusals,
  whole model selections, migrations, and preservation of user-owned keys.
  t3code-launch.py exercises the native launch composer and rendered files;
  test_t3_instructions.py covers preservation and removal of native options.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;
  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    fail=1
  '';

  cliEnabled = config: config.my.t3.cli.enable;
  desktopEnabled = config: config.my.t3.desktop.enable;

  cliTrait = configurations.withTrait "my.t3.cli.enable" cliEnabled;
  desktopTrait = configurations.withTrait "my.t3.desktop.enable" desktopEnabled;

  bootstrapGuard =
    label: predicate:
    lib.optionalString (!lib.any (entry: predicate entry.config) configurations.bootstraps) (
      fail "no bootstrap configuration enables ${label}, so the bootstrap profile is never checked for it"
    );

  # Each trait forced off alone leaves the other on, so the settings merge
  # needs configurations with both off for its negative side. Their profiles
  # are not read: the single-trait configurations already cover each package,
  # and reading them would build another home.path per host.
  bothOff = map (
    entry:
    configurations.entryOf "${entry.name} with both T3 Code traits forced off" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [
          {
            my.t3.cli.enable = lib.mkForce false;
            my.t3.desktop.enable = lib.mkForce false;
          }
        ];
      }
    )
  ) configurations.production;

  profileEntries = configurations.entries ++ cliTrait.disabled ++ desktopTrait.disabled;

  settingsExpectedBase = {
    set = {
      addProjectBaseDirectory = "~/src";
      autoResumeLimitedThreads = true;
      branchNamingMode = "semantic";
      defaultAutoPull = true;
      defaultThreadEnvMode = "worktree";
      defaultRuntimeMode = "full-access";
      sidebarAutoSettleOnMerge = true;
      sidebarAutoSettleAfterDays = 3;
      sidebarAutoSettleKeepPullRequests = true;
      enableAgentDeviceAccess = true;
      enableDeviceSupport = true;
      snoozeLimitedThreads = true;
    };
    remove = [ ];
    removePaths = [
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
    migrateInstances = {
      from = "providers";
      to = "providerInstances";
      kinds = [
        "antigravity"
        "claudeAgent"
        "codex"
        "grok"
        "opencode"
        "pi"
      ];
    };
    setPaths = lib.sort (a: b: (lib.concatStringsSep "." a.path) < (lib.concatStringsSep "." b.path)) [
      {
        path = [
          "providerInstances"
          "claudeAgent"
          "driver"
        ];
        value = "claudeAgent";
      }
      {
        path = [
          "providerInstances"
          "claudeAgent"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "codex"
          "config"
          "homePath"
        ];
        value = "~/.codex";
      }
      {
        path = [
          "providerInstances"
          "codex"
          "config"
          "setupMode"
        ];
        value = "existing";
      }
      {
        path = [
          "providerInstances"
          "codex"
          "driver"
        ];
        value = "codex";
      }
      {
        path = [
          "providerInstances"
          "codex"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "grok"
          "driver"
        ];
        value = "grok";
      }
      {
        path = [
          "providerInstances"
          "grok"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "opencode"
          "driver"
        ];
        value = "opencode";
      }
      {
        path = [
          "providerInstances"
          "opencode"
          "enabled"
        ];
        value = false;
      }
      {
        path = [
          "providerInstances"
          "pi"
          "driver"
        ];
        value = "pi";
      }
      {
        path = [
          "providerInstances"
          "pi"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "sourceControlWritingStyle"
          "mode"
        ];
        value = "conventional_commits";
      }
      {
        path = [
          "storageCleanup"
          "browserArtifactsAfterDays"
        ];
        value = 8;
      }
      {
        path = [
          "storageCleanup"
          "logsAfterDays"
        ];
        value = 8;
      }
      {
        path = [
          "storageCleanup"
          "worktreeAfterDays"
        ];
        value = 5;
      }
      {
        path = [
          "storageCleanup"
          "worktreeOnDelete"
        ];
        value = true;
      }
      {
        path = [
          "storageCleanup"
          "worktreeOnMerge"
        ];
        value = true;
      }
      {
        path = [
          "storageCleanup"
          "worktreeSettledAfterDays"
        ];
        value = 1;
      }
      {
        path = [
          "storageCleanup"
          "worktreeUnchanged"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "claudeAgent"
          "config"
          "idleCompaction"
        ];
        value = "beforeCacheExpires";
      }
      {
        path = [
          "providerInstances"
          "pi"
          "config"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "pi"
          "config"
          "binaryPath"
        ];
        value = "@PI@";
      }
      {
        path = [
          "providerInstances"
          "antigravity"
          "driver"
        ];
        value = "antigravity";
      }
      {
        path = [
          "providerInstances"
          "antigravity"
          "enabled"
        ];
        value = true;
      }
      {
        path = [
          "providerInstances"
          "antigravity"
          "config"
          "binaryPath"
        ];
        value = "@AGY@";
      }
      {
        path = [
          "sourceControlWritingStyle"
          "customInstructions"
        ];
        value = "";
      }
    ];
    own = {
      defaultModelSelection = {
        instanceId = "codex";
        model = "gpt-6.1-sol";
        options = [
          {
            id = "reasoningEffort";
            value = "high";
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
  };

  selectionSeed = {
    defaultModelSelection = {
      instanceId = "old-provider";
      model = "old-model";
      options = [
        {
          id = "staleOption";
          value = true;
        }
      ];
      staleField = "remove me";
    };
    textGenerationModelSelection = settingsExpectedBase.own.textGenerationModelSelection;
    unrelated.keep = true;
    providerInstances.codex.config.env.KEEP = "yes";
    projectSettingsOverrides.scratch.defaultModelSelection = {
      instanceId = "codex";
      model = "gpt-6.1-sol";
      options = [ ];
    };
  };

  clientSettingsExpectedBase = {
    set = {
      fontFamilySans = "Pretendard Variable";
      fontFamilyCode = "Jetendard";
      fontFamilyTerminal = "Jetendard";
      notificationMode = "notifications";
      inAppNotificationsEnabled = true;
      sidebarWorkingShelfEnabled = true;
      snapShotEnabled = true;
    };
    remove = [ ];
    setPaths = [ ];
    own = { };
  };
  # Without string context, so the scripts the activation names are not built:
  # the check compares the paths, and the paths are the store hashes of what
  # the module would install.
  noContext = builtins.unsafeDiscardStringContext;

  profileBinaries = {
    "@PI@" = "pi";
    "@AGY@" = "agy_acp_server.par";
  };

  merges = [
    {
      attr = "t3codeSettings";
      file = "settings.json";
      contract = settingsExpectedBase;
    }
    {
      attr = "t3codeClientSettings";
      file = "client-settings.json";
      contract = clientSettingsExpectedBase;
    }
  ];

  # Every lookup has an `or` fallback, so a removed declaration reaches the
  # builder as an empty argument instead of failing evaluation.
  # pluginsDeclared is false for the module evaluated on its own, which has no
  # agentPlugins entry to exist.
  assertSettingsWith =
    pluginsDeclared: name: user: expected:
    lib.concatMapStrings (
      merge:
      let
        activation = user.home.activation.${merge.attr} or null;
      in
      ''
        checkSettings ${esc name} ${merge.attr} ${lib.boolToString expected} ${
          lib.boolToString (activation != null)
        } ${esc (activation.data or "")} ${
          lib.boolToString (lib.elem "installPackages" (activation.after or [ ]))
        } ${lib.boolToString pluginsDeclared}
      ''
      + lib.optionalString (expected && activation != null) ''
        if ! (
          failed=0
          ${executeActivation {
            script = activation.data or "";
            home = user.home.homeDirectory or "";
            contract = {
              file = ".t3/userdata/${merge.file}";
              declared =
                if merge.attr == "t3codeSettings" then
                  merge.contract
                  // {
                    setPaths = map (
                      row:
                      if lib.isString row.value && lib.hasAttr row.value profileBinaries then
                        row
                        // {
                          value = noContext "${
                            user.home.profileDirectory or "${user.home.homeDirectory}/.nix-profile"
                          }/bin/${profileBinaries.${row.value}}";
                        }
                      else
                        row
                    ) merge.contract.setPaths;
                  }
                else
                  merge.contract;
            }
            // lib.optionalAttrs (merge.attr == "t3codeSettings") {
              seed = selectionSeed;
              preservePaths = [
                [ "unrelated" ]
                [ "projectSettingsOverrides" ]
                [
                  "providerInstances"
                  "codex"
                  "config"
                  "env"
                ]
              ];
            };
          }}
          exit "$failed"
        ); then
          echo ${esc "${name}: the generated activation did not apply the startup selection"} >&2
          fail=1
        fi
      ''
    ) merges;

  assertSettings = assertSettingsWith true;

  assertSignIn =
    name: user: expected:
    let
      activation = user.home.activation.antigravitySignIn or null;
    in
    ''
      checkSignIn ${esc name} ${lib.boolToString expected} ${
        lib.boolToString (activation != null)
      } ${esc (activation.data or "")} ${
        lib.boolToString (lib.elem "t3codeSettings" (activation.after or [ ]))
      } ${esc (user.home.homeDirectory or "")}
    '';

  assertSettingsOn =
    entry:
    assertSettings entry.name entry.user (cliEnabled entry.config || desktopEnabled entry.config)
    + assertSignIn entry.name entry.user (cliEnabled entry.config || desktopEnabled entry.config);

  assertProfile = entry: ''
    checkProfile ${esc entry.name} ${
      esc (entry.user.home.path or "")
    } ${lib.boolToString (cliEnabled entry.config)} ${lib.boolToString (desktopEnabled entry.config)}
    ${assertSettingsOn entry}
  '';

  # The module reaches lib.hm, which only Home Manager's extended lib carries.
  hmLib = import "${self.inputs.home-manager}/modules/lib/stdlib-extended.nix" lib;

  # The module on its own, so the assertion's message and the packages it
  # would otherwise let through can be read. NixOS is the control: there the
  # desktop app installs and nothing fails.
  moduleWith =
    module: kind:
    let
      config =
        (hmLib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            ../modules/shared/host.nix
            module
            {
              options.assertions = lib.mkOption {
                type = lib.types.listOf lib.types.unspecified;
                default = [ ];
              };
              options.home.packages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              options.launchd.agents = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
              options.home.activation = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
              options.home.file = lib.mkOption {
                type = lib.types.attrsOf lib.types.unspecified;
                default = { };
              };
              options.home.homeDirectory = lib.mkOption {
                type = lib.types.str;
                default = "/home/probe";
              };
              config.my = {
                hostName = "probe";
                inherit kind;
                t3.desktop.enable = true;
              };
            }
          ];
        }).config;
    in
    {
      inherit config;
      failed = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
      desktopInstalled = lib.elem "t3code-desktop" (map lib.getName config.home.packages);
      updaterOff =
        let
          agent = config.launchd.agents.t3code-disable-auto-update or { };
        in
        (agent.enable or false)
        &&
          (agent.config.ProgramArguments or [ ]) == [
            "/bin/launchctl"
            "setenv"
            "T3CODE_DISABLE_AUTO_UPDATE"
            "1"
          ];
    };

  moduleOn = moduleWith ../home/h82/t3code.nix;

  launchManifest = import ./lib/t3code-launch-manifest.nix {
    inherit pkgs;
    users = map (kind: (moduleOn kind).config) [
      "nixos"
      "darwin"
    ];
  };

  assertModule =
    let
      nixos = moduleOn "nixos";
      darwin = moduleOn "darwin";
    in
    lib.concatStrings [
      (lib.optionalString (nixos.failed != [ ]) (
        fail "NixOS with my.t3.desktop.enable: assertions fail: ${builtins.toJSON nixos.failed}"
      ))
      (lib.optionalString (!nixos.desktopInstalled) (
        fail "NixOS with my.t3.desktop.enable: the T3 Code desktop package is not added"
      ))
      (lib.optionalString nixos.updaterOff (
        fail "NixOS with my.t3.desktop.enable: the macOS updater-off launchd agent is declared"
      ))
      (lib.optionalString (darwin.failed != [ ]) (
        fail "macOS with my.t3.desktop.enable: assertions fail: ${builtins.toJSON darwin.failed}"
      ))
      (lib.optionalString (!darwin.desktopInstalled) (
        fail "macOS with my.t3.desktop.enable: the T3 Code desktop package is not added"
      ))
      (lib.optionalString (!darwin.updaterOff) (
        fail "macOS with my.t3.desktop.enable: no launchd agent runs launchctl setenv T3CODE_DISABLE_AUTO_UPDATE 1, so the copied app can update itself off the pin"
      ))
      (assertSettingsWith false "NixOS module with my.t3.desktop.enable" nixos.config true)
      (assertSettingsWith false "macOS module with my.t3.desktop.enable" darwin.config true)
      (assertSignIn "NixOS module with my.t3.desktop.enable" nixos.config true)
      (assertSignIn "macOS module with my.t3.desktop.enable" darwin.config true)
    ];
in
pkgs.runCommand "t3code-traits" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  fail=0
  ${configurations.guard}
  ${cliTrait.guard}
  ${desktopTrait.guard}
  ${bootstrapGuard "my.t3.cli.enable" cliEnabled}
  ${bootstrapGuard "my.t3.desktop.enable" desktopEnabled}

  # True when $1 exists and resolves into a store path of package $2.
  resolvesInto() {
    [ -e "$1" ] || return 1
    case $(readlink -f "$1") in
      /nix/store/*-"$2"-*) return 0 ;;
    esac
    return 1
  }

  # Fails unless $3 resolving into package $4 matches the trait value $5.
  expectPresence() {
    local name=$1 what=$2 path=$3 pkg=$4 expected=$5 trait=$6 present=false
    resolvesInto "$path" "$pkg" && present=true
    if [ "$present" != "$expected" ]; then
      echo "$name: $what is present=$present, $trait is $expected" >&2
      fail=1
    fi
  }

  checkProfile() {
    local name=$1 profile=$2 cli=$3 desktop=$4 target exe
    if [ -z "$profile" ] || [ ! -d "$profile" ]; then
      echo "$name: Home Manager renders no home.path" >&2
      fail=1
      return
    fi

    expectPresence "$name" "bin/t3 from t3code-cli" "$profile/bin/t3" t3code-cli "$cli" my.t3.cli.enable
    expectPresence "$name" "the t3code.desktop entry" "$profile/share/applications/t3code.desktop" t3code-desktop "$desktop" my.t3.desktop.enable
    expectPresence "$name" "bin/t3code-desktop" "$profile/bin/t3code-desktop" t3code-desktop "$desktop" my.t3.desktop.enable

    for exe in "$profile"/bin/*; do
      target=$(readlink -f "$exe")
      case $target in
        /nix/store/*-t3code-cli-* | /nix/store/*-t3code-desktop-*)
          case ''${exe##*/} in
            t3 | t3code-desktop) ;;
            *)
              echo "$name: bin/''${exe##*/} on PATH comes from a T3 Code package ($target)" >&2
              fail=1
              ;;
          esac
          ;;
      esac
    done
  }

  # Trait/order checks stay here; the shared file-effect harness owns settings
  # invocation, destination/declaration, refusal and dry-run behavior.
  checkSettings() {
    local name=$1 attr=$2 expected=$3 present=$4 after=$6 full=$7 merger declared
    if [ "$present" != "$expected" ]; then
      echo "$name: home.activation.$attr is present=$present, either T3 Code trait on is $expected" >&2
      fail=1
      return
    fi
    [ "$present" = true ] || return 0

    if [ "$after" != true ]; then
      echo "$name: home.activation.$attr must run after installPackages" >&2
      fail=1
    fi

    printf '%s\n' "$5" > script
    merger=$(grep -oE '/nix/store/[^[:space:]]+/bin/agent-settings' script | head -n 1 || true)
    if [ -z "$merger" ]; then
      echo "$name: the $attr activation names no packaged merger" >&2
      fail=1
      return
    fi
    declared=$(sed -n 's/.*--declared \([^ ]*\).*/\1/p' script | tr -d "'\"")
    if [ "$attr" = t3codeSettings ] && [ -n "$declared" ] \
      && ! python3 -I ${./t3code-codex-home.py} "$declared" 2> codex-home.log; then
      echo "$name: a declared Codex instance can run outside ~/.codex:" >&2
      cat codex-home.log >&2
      fail=1
    fi

    [ "$attr" = t3codeSettings ] || return 0
    [ "$full" = true ] || return 0
    checkOpencodeDisabled "$name" "$merger" "$declared"
    checkAntigravityInstance "$name" "$merger" "$declared"
  }

  checkAntigravityInstance() {
    local name=$1 realMerger=$2 declared=$3
    if ! python3 -I ${./t3code-antigravity-instance.py} instance "$realMerger" "$declared" \
      2> antigravity-instance.log; then
      echo "$name: the merge does not set the declared Antigravity instance leaves and keep its siblings:" >&2
      cat antigravity-instance.log >&2
      fail=1
    fi
  }

  checkSignIn() {
    local name=$1 expected=$2 present=$3 after=$5 home=$6
    if [ "$present" != "$expected" ]; then
      echo "$name: home.activation.antigravitySignIn is present=$present, either T3 Code trait on is $expected" >&2
      fail=1
      return
    fi
    [ "$present" = true ] || return 0

    if [ "$after" != true ]; then
      echo "$name: home.activation.antigravitySignIn must run after t3codeSettings" >&2
      fail=1
    fi
    printf '%s\n' "$4" > signin-script
    if ! python3 -I ${./t3code-antigravity-instance.py} signin signin-script "$home" \
      2> antigravity-signin.log; then
      echo "$name: the sign-in activation does not link the standard token path to T3 Code's instance token:" >&2
      cat antigravity-signin.log >&2
      fail=1
    fi
  }

  # Merges the declared document into a settings.json that holds an enabled
  # opencode instance and OpenCode's hidden-model preference with the real
  # merger: the merged file must hold the instance disabled and the preference
  # gone, also on a second run, and keep the keys the declaration does not
  # touch. $2 is the packaged merger and $3 the declaration the activation
  # passed it.
  checkOpencodeDisabled() {
    local name=$1 realMerger=$2 declared=$3
    if ! python3 -I ${./t3code-opencode-disabled.py} "$realMerger" "$declared" 2> opencode-disabled.log; then
      echo "$name: the merged settings.json does not hold the opencode instance disabled:" >&2
      cat opencode-disabled.log >&2
      fail=1
    fi
  }


  python3 -I ${./t3code-launch.py} ${launchManifest}
  T3_INSTRUCTIONS_SCRIPT=${../scripts/t3-instructions.py} python3 -I ${./test_t3_instructions.py}
  ${lib.concatMapStrings assertProfile profileEntries}
  ${lib.concatMapStrings assertSettingsOn bothOff}
  ${assertModule}

  [ "$fail" = 0 ] || exit 1
  touch "$out"
''
