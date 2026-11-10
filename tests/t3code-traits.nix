/*
  Check interface:

    import ./tests/t3code-traits.nix { inherit pkgs self fixtures; }

  `fixtures` is tests/lib/linux-fixtures.nix. Guards the two T3 Code traits,
  my.t3.cli.enable and my.t3.desktop.enable, which home/h82/t3code.nix turns
  into user packages.

  On every NixOS configuration, production and bootstrap, and on each
  production configuration re-evaluated with one trait forced off, the
  materialized user profile (home.path, which useUserPackages makes the
  per-user profile) is read rather than the package list:
  - bin/t3 resolves into the t3code-cli package exactly when the CLI trait is
    on;
  - share/applications/t3code.desktop and bin/t3code-desktop resolve into the
    t3code-desktop package exactly when the desktop trait is on;
  - nothing else on PATH comes from a T3 Code package, so T3 Code brings no
    claude of its own and its sessions run the flake's.
  - home.activation.t3codeSettings and home.activation.t3codeClientSettings
    exist exactly when either trait is on and run after installPackages. Each
    script is executed by the shared agent-activation harness against scratch
    files, checking destination/declaration, real file effects, repeat apply,
    dry-run byte protection and refusal propagation. The
    settings.json declaration names the provider instances' leaves: the
    enabled Antigravity, Claude, Codex, Grok, and one OMP instance, the
    disabled Pi and OpenCode instances, the Claude instance's launch arguments emptied,
    which retires the --add-dir an earlier generation wrote, no environment
    entry upserted, and the Codex instance's launch arguments emptied, which
    retires the developer_instructions override an earlier generation wrote; the
    retired `providers` block of those six instances is migrated into them
    first. The Antigravity instance names the executable of the runtime built
    from the release the pinned T3 Code embeds, by store path;
    tests/t3code-antigravity-instance.py reads the rendered declaration and
    fails when that path is not inside that runtime, is not a store path (so
    could resolve through PATH or ~/.t3/tools), names the PATH wrapper's
    runtime while the two pins differ, or when the pin does not record the
    localharness_external T3 Code looks for beside it; it also runs the real
    merger over a settings.json that already holds an antigravity instance
    with app state, which must survive with the declared path and enabled.
    The Codex instance also declares `~/.codex` as its home path and
    the non-managed `existing` setup mode, so neither a home or managed setup
    set in the app nor a CODEX_HOME in the instance's environment can move it;
    tests/t3code-codex-home.py reads the rendered declaration and fails when
    any instance with driver "codex" leaves either undeclared, names another
    home, or declares `managed`, since
    T3 Code's Codex sessions must run on ~/.codex, where the plugin sync and
    the skills land. The Pi instance declares no binaryPath and no launch arguments.
    The declaration retires providerModelPreferences.opencode, which an
    earlier generation wrote, and merges "default" into
    providerModelPreferences.omp.hiddenModels via prefixEntries. On a full
    configuration, the real merger also runs over a settings.json that holds
    an enabled opencode instance, that preference, and another provider's:
    the merged file must hold the instance disabled, the opencode preference
    gone, the other provider's preference preserved, and omp's hiddenModels
    carrying "default".
  The same holds on each non-NixOS fixture host of the builder's
  architecture, production and bootstrap, and on each bootstrap fixture
  re-assembled with only the CLI trait forced on, since the CLI is the T3
  Code those hosts support.
  Today every NixOS configuration enables both traits, so the forced-off
  configurations, including one per production configuration with both traits
  off, are what keep each "exactly when" from passing on the positive side
  alone. Some production and some bootstrap configuration must enable each
  trait.

  On every non-NixOS fixture host's bootstrap variant, re-assembled through
  lib/linux-host.nix with my.t3.desktop.enable forced on, Home Manager
  refuses to evaluate, while the fixture as declared evaluates. Home Manager
  throws on a failed assertion before its output can be read, so
  home/h82/t3code.nix is also evaluated on its own: on a non-NixOS Linux kind
  its assertion reports that the desktop app runs on NixOS and macOS only and
  the desktop package is not added; on NixOS nothing fails and the package is
  added; on macOS nothing fails, the package is added, and a launchd agent
  sets T3CODE_DISABLE_AUTO_UPDATE=1 for GUI launches, which NixOS does not get.
  On NixOS and macOS the module also declares both settings merges, checked
  the same way as on the assembled configurations, since no macOS
  configuration is evaluated here.

  Every failure is collected in one build and names the configuration.
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

  # The Antigravity runtime behind the instance is built from the pinned T3
  # Code's embedded release, the one behind the PATH wrapper from Google's
  # newest. Neither is built here: the archives weigh hundreds of megabytes, so
  # the check compares the store paths the module would install.
  t3AntigravityRuntime = import ../packages/antigravity-acp.nix {
    inherit pkgs;
    pins = (builtins.fromJSON (builtins.readFile ../packages/t3code-release.json)).antigravity;
  };
  pathAntigravityRuntime = import ../packages/antigravity-acp.nix {
    inherit pkgs;
    pins = (builtins.fromJSON (builtins.readFile ../packages/antigravity-acp-release.json)).platforms;
  };
  t3Pin = t3AntigravityRuntime.pin;
  t3AntigravityDir = "${t3AntigravityRuntime}/libexec/antigravity-acp";
  pinsDiffer = t3AntigravityRuntime.version != pathAntigravityRuntime.version;
  pathAntigravityDir = "${pathAntigravityRuntime}/libexec/antigravity-acp";

  settingsExpectedBase = {
    set = {
      addProjectBaseDirectory = "~/src";
      autoResumeLimitedThreads = true;
      branchNamingMode = "semantic";
      defaultAutoPull = true;
      defaultThreadEnvMode = "worktree";
      enableAgentDeviceAccess = true;
      enableDeviceSupport = true;
      snoozeLimitedThreads = true;
    };
    remove = [ ];
    removePaths = [
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
    prefixEntries = [
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
    migrateInstances = {
      from = "providers";
      to = "providerInstances";
      kinds = [
        "antigravity"
        "claudeAgent"
        "codex"
        "grok"
        "omp"
        "opencode"
        "pi"
      ];
    };
    setPaths = [
      {
        path = [
          "providerInstances"
          "antigravity"
          "config"
          "binaryPath"
        ];
        value = noContext "${t3AntigravityDir}/${t3Pin.executable.name}";
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
          "claudeAgent"
          "config"
          "launchArgs"
        ];
        value = "";
      }
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
          "launchArgs"
        ];
        value = "";
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
          "omp"
          "displayName"
        ];
        value = "OMP";
      }
      {
        path = [
          "providerInstances"
          "omp"
          "driver"
        ];
        value = "acpRegistry";
      }
      {
        path = [
          "providerInstances"
          "omp"
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
        value = false;
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
        value = 8;
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
    ];
    ownEntries =
      map
        (id: {
          path = [
            "providerInstances"
            id
            "config"
          ];
          entries = {
            source = "local";
            commandPath = noContext "${import ../packages/omp.nix { inherit pkgs; }}/bin/omp";
            # omp-acp owns custom selectors, runtime scope and defaults.
          };
        })
        [
          "omp"
        ];
    own = {
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
    set.fontFamilyCode = "JetBrains Mono";
    remove = [ ];
    setPaths = [ ];
    own = { };
  };
  # Without string context, so the scripts the activation names are not built:
  # the check compares the paths, and the paths are the store hashes of what
  # the module would install.
  noContext = builtins.unsafeDiscardStringContext;

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
              declared = merge.contract;
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

  assertSettingsOn =
    entry:
    assertSettings entry.name entry.user (cliEnabled entry.config || desktopEnabled entry.config);

  assertProfile = entry: ''
    checkProfile ${esc entry.name} ${
      esc (entry.user.home.path or "")
    } ${lib.boolToString (cliEnabled entry.config)} ${lib.boolToString (desktopEnabled entry.config)}
    ${assertSettingsOn entry}
  '';

  desktopMessage = "the T3 Code desktop app runs on NixOS and macOS only";

  # Home Manager throws on a failed assertion before any part of the output
  # can be read, so an assembled fixture can only show that evaluation is
  # refused. The same fixture without the trait must evaluate, so the refusal
  # is the trait's. Only bootstrap variants are re-assembled: production needs
  # the fixtures' fake secrets, and without them it fails on its own.
  evaluates = home: (builtins.tryEval home.config.home.username).success;

  mkLinuxHost = import ../lib/linux-host.nix { inherit (self) inputs; };

  assertFixture =
    entry:
    let
      forced = mkLinuxHost {
        hostName = entry.fixture;
        dir = ./fixtures/hosts + "/${entry.fixture}";
        bootstrap = true;
        extraModules.home = [ { my.t3.desktop.enable = true; } ];
      };
    in
    lib.concatStrings [
      (lib.optionalString (!evaluates entry.host.home) (
        fail "${entry.name}: the fixture as declared does not evaluate"
      ))
      (lib.optionalString (evaluates forced.home) (
        fail "${entry.name} with my.t3.desktop.enable forced on: Home Manager evaluates instead of refusing the desktop app"
      ))
    ];

  # The CLI is the T3 Code a non-NixOS host supports, and no fixture of every
  # architecture enables it, so the merge's positive side is checked on a
  # bootstrap fixture with the CLI forced on. Only this architecture's
  # fixtures, because the activation script interpolates their store paths.
  assertFixtureCli =
    entry:
    let
      forced = mkLinuxHost {
        hostName = entry.fixture;
        dir = ./fixtures/hosts + "/${entry.fixture}";
        bootstrap = true;
        extraModules.home = [
          {
            my.t3.cli.enable = lib.mkForce true;
            my.t3.desktop.enable = lib.mkForce false;
          }
        ];
      };
    in
    assertSettings "${entry.name} with only my.t3.cli.enable forced on" forced.home.config true;

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

  assertModule =
    let
      linux = moduleOn "linux";
      nixos = moduleOn "nixos";
      darwin = moduleOn "darwin";
    in
    lib.concatStrings [
      (lib.optionalString (!lib.any (lib.hasInfix desktopMessage) linux.failed) (
        fail "non-NixOS with my.t3.desktop.enable: no assertion reports that ${desktopMessage}; failed assertions: ${builtins.toJSON linux.failed}"
      ))
      (lib.optionalString linux.desktopInstalled (
        fail "non-NixOS with my.t3.desktop.enable: the T3 Code desktop package is added, so the host fails a build rather than the assertion"
      ))
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
        fail "macOS with my.t3.desktop.enable: no launchd agent runs launchctl setenv T3CODE_DISABLE_AUTO_UPDATE 1, so the copied app can update itself off the nightly pin"
      ))
      (assertSettingsWith false "NixOS module with my.t3.desktop.enable" nixos.config true)
      (assertSettingsWith false "macOS module with my.t3.desktop.enable" darwin.config true)
    ];
in
pkgs.runCommand "t3code-traits" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  fail=0
  ${configurations.guard}
  ${cliTrait.guard}
  ${desktopTrait.guard}
  ${bootstrapGuard "my.t3.cli.enable" cliEnabled}
  ${bootstrapGuard "my.t3.desktop.enable" desktopEnabled}
  ${lib.optionalString (fixtures == [ ]) (fail "tests/fixtures/hosts holds no fixture host")}

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

  # The declared Antigravity instance names the T3-pinned runtime's executable
  # by store path, and the real merger keeps an existing instance's app state.
  # The harness binary the pin records sits in the same directory by the
  # builder's construction; the runtime is not built here.
  checkAntigravityInstance() {
    local name=$1 realMerger=$2 declared=$3
    if ! python3 -I ${./t3code-antigravity-instance.py} "$realMerger" "$declared" \
      ${esc (noContext t3AntigravityDir)} ${
        esc (if pinsDiffer then noContext pathAntigravityDir else "-")
      } \
      ${esc t3Pin.executable.name} ${esc t3Pin.harness.name} 2> antigravity-instance.log; then
      echo "$name: the Antigravity instance is not the T3-pinned runtime or the merge drops it:" >&2
      cat antigravity-instance.log >&2
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


  ${lib.concatMapStrings assertProfile profileEntries}
  ${lib.concatMapStrings assertSettingsOn bothOff}
  ${lib.concatMapStrings (
    entry:
    let
      home = entry.host.home.config;
    in
    assertSettings entry.name home (home.my.t3.cli.enable || home.my.t3.desktop.enable)
  ) configurations.linuxFixtures}
  ${lib.concatMapStrings assertFixtureCli (
    lib.filter (entry: entry.bootstrap) configurations.linuxFixtures
  )}
  ${lib.concatMapStrings assertFixture (lib.filter (entry: entry.bootstrap) fixtures)}
  ${assertModule}

  [ "$fail" = 0 ] || exit 1
  touch "$out"
''
