{
  description = "Declarative NixOS configuration for personal hosts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Applies the system layer of a non-NixOS host: /etc files and systemd
    # units on a distribution this flake does not own.
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Applies the system layer of a macOS host, with Home Manager inside it.
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Installs Homebrew itself on a macOS host, so the first apply needs no
    # manual Homebrew install; nix-darwin's homebrew module installs the casks.
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    # Boots a foreign distribution's cloud image for the non-NixOS VM check.
    nix-vm-test = {
      url = "github:numtide/nix-vm-test";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned to a release tag rather than a branch, and the registry in
    # home/h82/agents/agent-plugin-pins.nix records the revision that tag is expected to
    # name. A tag is mutable and a relock re-resolves the ref, so the tag alone
    # is not a pin -- the agent-plugins check compares this input's locked
    # revision against that recorded value and fails when upstream moves it.
    compound-engineering-plugin = {
      url = "github:EveryInc/compound-engineering-plugin/compound-engineering-v3.33.1";
      flake = false;
    };
    korean-skills = {
      url = "github:DaleSeo/korean-skills/v1.0.0";
      flake = false;
    };
    # Published design and stack skills, installed unchanged. Each is pinned to
    # a tag where upstream has one and to a commit otherwise; the registry in
    # home/h82/agents/pinned-skills-pin.nix records the revision each must
    # resolve to, and the pinned-skills check compares it with flake.lock.
    anthropic-skills = {
      url = "github:anthropics/skills/dbd4588f9e1033efb41dad4bef2f7947c8993d44";
      flake = false;
    };
    vercel-agent-skills = {
      url = "github:vercel-labs/agent-skills/agent-skills-1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62";
      flake = false;
    };
    expo-skills = {
      url = "github:expo/skills/8a0dc4fa57ae345923c357e1451cbcd8b6f2a7db";
      flake = false;
    };
    playwright-best-practices-skill = {
      url = "github:currents-dev/playwright-best-practices-skill/283d5cbc5d11aac1abda058b16ad22c317d54dc0";
      flake = false;
    };
    ux-writing-skill = {
      url = "github:content-designer/ux-writing-skill/v1.5.0";
      flake = false;
    };
    kergoth-dotfiles = {
      url = "github:kergoth/dotfiles/7f61f919d27e3016b64c37ce09b7006199ad7878";
      flake = false;
    };
    impeccable = {
      url = "github:pbakaus/impeccable/skill-v4.8.0";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      agentTools = import ./packages/agent-tools.nix { inherit pkgs; };
      inherit (nixpkgs) lib;

      # Each directory under hosts/ is a host, named by the directory. One that
      # holds host.nix is a Linux or macOS host, by the kind host.nix names;
      # every other one is a NixOS host.
      hosts = import ./lib/hosts.nix { inherit lib; } ./hosts;

      # Both variants of every host one assembly builds, keyed by output name.
      variantsOf =
        mkHost: hostNames:
        lib.listToAttrs (
          lib.concatMap (hosts.withVariants (
            hostName: bootstrap:
            mkHost {
              inherit hostName bootstrap;
              dir = ./hosts + "/${hostName}";
            }
          )) hostNames
        );
      linuxHosts = variantsOf (import ./lib/linux-host.nix { inherit inputs; }) hosts.linux;
      darwinHosts = variantsOf (import ./lib/darwin-host.nix { inherit inputs; }) hosts.darwin;
      darwinFixtures = import ./tests/lib/darwin-fixtures.nix { inherit inputs; };

      # The non-NixOS fixture hosts build on their own architecture, so each
      # system's checks carry the fixtures of that system.
      linuxFixtures = import ./tests/lib/linux-fixtures.nix { inherit inputs; };
      fixtureChecksFor = import ./tests/lib/fixture-checks.nix { inherit lib linuxFixtures; };
      vmChecks = import ./tests/vm-checks.nix { inherit pkgs inputs linuxFixtures; };
      checkShards = import ./tests/check-shards.nix {
        inherit pkgs;
        checks = self.checks.${system};
        # The checks whose closure carries a host generation, found by
        # sweeping each check's .drv closure for a NixOS system-path or a Home
        # Manager or system-manager generation. The fixture checks are listed
        # through fixtureChecksFor because their names embed a fixture host.
        hostClosureChecks = [
          "agent-browser-deps"
          "agent-instructions"
          "android-sdk"
          "antigravity-profiles"
          "antigravity-skills"
          "baloo-extractor"
          "cargo-settings"
          "desktop-autostart"
          "desktop-ssh"
          "elf-load-segments"
          "emoji-font"
          "gemini"
          "ghostty-font"
          "ghq"
          "git-lfs"
          "git-trim"
          "gpg-agent-no-cache"
          "kde-theme"
          "kernel-sysctl"
          "korean-skills"
          "kubernetes-tools"
          "minikube-autostart"
          "mise-settings"
          "nix-cleanup"
          "non-nixos-outputs"
          "omp-models-load"
          "omp-settings"
          "pinned-skills"
          "podman-containers"
          "printing"
          "proton-vpn"
          "python3-runtime"
          "serve-html-profiles"
          "session-variables"
          "shell-utilities"
          "ssh-server"
          "t3code-traits"
          "test-audit-skill"
          "tokscale"
          "udev-device-access"
          "user-avatar"
          "vscodium"
          "wifiman"
          "winbox"
          "yubikey-fido"
          "zsh-prezto"
        ]
        ++ lib.attrNames (fixtureChecksFor system);
        lightCount = 3;
      };
    in
    {
      homeConfigurations = lib.mapAttrs (_: host: host.home) linuxHosts;
      systemConfigs = lib.mapAttrs (_: host: host.systemManager) linuxHosts;
      checks.aarch64-linux = fixtureChecksFor "aarch64-linux" // {
        omp-settings = import ./tests/omp-settings.nix {
          pkgs = import nixpkgs { system = "aarch64-linux"; };
          inherit self;
          fixtures = linuxFixtures;
        };
        omp-models-load = import ./tests/omp-models-load.nix {
          pkgs = import nixpkgs { system = "aarch64-linux"; };
          inherit self;
          fixtures = linuxFixtures;
        };
        omp-acp = import ./tests/omp-acp.nix {
          pkgs = import nixpkgs { system = "aarch64-linux"; };
          inherit self;
          fixtures = linuxFixtures;
        };
      };
      packages.aarch64-linux.omp = import ./packages/omp.nix {
        pkgs = import nixpkgs { system = "aarch64-linux"; };
      };
      packages.aarch64-darwin.omp = import ./packages/omp.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
      };
      checks.aarch64-darwin.omp-settings = import ./tests/omp-settings.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        inherit self;
      };
      checks.aarch64-darwin.omp-models-load = import ./tests/omp-models-load.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        inherit self;
      };
      checks.aarch64-darwin.omp-acp = import ./tests/omp-acp.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        inherit self;
      };
      # Reads what the macOS fixture hosts materialize, so building it builds
      # both fixture systems; only a macOS builder can.
      checks.aarch64-darwin.darwin-outputs = import ./tests/darwin-outputs.nix {
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
        inherit darwinFixtures;
        darwinConfigurations = darwinHosts;
      };
      darwinConfigurations = darwinHosts;

      nixosConfigurations =
        let
          mkHost = import ./lib/nixos-host.nix { inherit inputs; };
        in
        lib.listToAttrs (
          lib.concatMap (hosts.withVariants (
            hostName: bootstrap: mkHost { inherit hostName bootstrap; }
          )) hosts.nixos
        );
      packages.${system} = {
        disko = inputs.disko.packages.${system}.disko;
        # Exposed so the release-tracking workflow invokes the packaged helper
        # rather than running scripts/ with whatever interpreter the runner has.
        agent-plugin-release = agentTools.agentPluginRelease;
        chatgpt-release = agentTools.chatgptRelease;
        chatgpt = import ./packages/chatgpt.nix { inherit pkgs; };
        claude-desktop-release = agentTools.claudeDesktopRelease;
        claude-desktop = import ./packages/claude-desktop.nix { inherit pkgs; };
        wifiman-desktop-release = agentTools.wifimanDesktopRelease;
        wifiman-desktop = import ./packages/wifiman-desktop.nix { inherit pkgs; };
        claude-code-release = agentTools.claudeCodeRelease;
        claude-code = import ./packages/claude-code.nix { inherit pkgs; };
        mise-release = agentTools.miseRelease;
        mise = import ./packages/mise.nix { inherit pkgs; };
        codex-release = agentTools.codexRelease;
        codex = import ./packages/codex.nix { inherit pkgs; };
        omp = import ./packages/omp.nix { inherit pkgs; };
        omp-release = agentTools.ompRelease;
        grok-build-release = agentTools.grokBuildRelease;
        grok-build = import ./packages/grok-build.nix { inherit pkgs; };
        npm-release = agentTools.npmRelease;
        acpx = import ./packages/acpx.nix { inherit pkgs; };
        tanstack-intent = import ./packages/tanstack-intent.nix { inherit pkgs; };
        antigravity-cli-release = agentTools.antigravityCliRelease;
        antigravity-cli = import ./packages/antigravity-cli.nix { inherit pkgs; };
        antigravity-acp-release = agentTools.antigravityAcpRelease;
        antigravity-acp = import ./packages/antigravity-acp.nix {
          inherit pkgs;
          pins = (builtins.fromJSON (builtins.readFile ./packages/antigravity-acp-release.json)).platforms;
        };
        antigravity-acp-path = import ./packages/antigravity-acp-path.nix { inherit pkgs; };
        t3code-release = agentTools.t3codeRelease;
        synthetic-models-watch = agentTools.syntheticModelsWatch;
        openrouter-catalog-snapshot = agentTools.openrouterCatalogSnapshot;
        t3code = import ./packages/t3code.nix { inherit pkgs; };
        t3code-cli = import ./packages/t3code-cli.nix { inherit pkgs; };
        android-sdk-release = agentTools.androidSdkRelease;
      };
      # VM tests live outside `checks` so `nix flake check` stays fast and needs
      # no KVM. legacyPackages, unlike an unknown top-level output, draws no
      # flake check warning, and `nix build .#vmChecks.<name>` resolves here.
      legacyPackages.${system} = {
        vmChecks = vmChecks // {
          all = pkgs.linkFarm "vm-checks" vmChecks;
        };
        # CI builds the checks one shard per job; `nix flake check` still
        # builds them all at once.
        checkShards = checkShards.shards;
      };
      checks.${system} =
        let
          configurations = import ./tests/lib/configurations.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };

          # Runs `assertConfiguration` over every configuration the flake builds.
          # Each per-configuration fragment records a failure in `fail` instead of
          # exiting, so one red build names every affected configuration.
          forEveryConfiguration = assertConfiguration: ''
            ${configurations.guard}
            fail=0
            ${pkgs.lib.concatMapStrings assertConfiguration configurations.entries}
            [ "$fail" = 0 ] || exit 1
          '';

          # Runs `assertUser` over every Home Manager user environment the flake
          # builds for this architecture, NixOS and non-NixOS hosts alike.
          forEveryUser = assertUser: ''
            ${configurations.userGuard}
            fail=0
            ${pkgs.lib.concatMapStrings assertUser configurations.userEntries}
            [ "$fail" = 0 ] || exit 1
          '';

          # A configuration whose user went missing reports each package as
          # absent inside the builder rather than aborting evaluation.
          userPackagesOf = entry: entry.user.home.packages or [ ];

          # The user package with this pname, or null when none is installed.
          userPackageOf =
            pname: entry: pkgs.lib.lists.findFirst (p: (p.pname or "") == pname) null (userPackagesOf entry);

          # Fetches every platform a release pin names, not only this system's,
          # so a wrong URL or hash for a platform no Linux job builds fails on
          # the x86_64 updater before the pin reaches main.
          pinnedSources =
            name: pinFile:
            pkgs.linkFarm name (
              pkgs.lib.mapAttrs (_: platform: pkgs.fetchurl { inherit (platform) url hash; })
                (builtins.fromJSON (builtins.readFile pinFile)).platforms
            );

          # Home Manager file targets of one user environment.
          homeFileTargets =
            entry: map (file: file.target or "") (builtins.attrValues (entry.user.home.file or { }));

          # Runs a stdlib Python test against a copy of the one script it drives
          # and of the modules it imports.
          optionalLines = text: pkgs.lib.optionalString (text != "") "\n${pkgs.lib.removeSuffix "\n" text}";
          pythonScriptCheckWith =
            {
              setup ? "",
              extra ? "",
              modules ? [ ],
              nativeBuildInputs ? [ ],
            }:
            name: script: test:
            pkgs.runCommand "${name}-tests" { nativeBuildInputs = [ pkgs.python3 ] ++ nativeBuildInputs; } ''
              export PYTHONDONTWRITEBYTECODE=1
              mkdir -p scripts tests
              cp ${script} scripts/${baseNameOf script}${
                pkgs.lib.concatMapStrings (module: "\ncp ${module} scripts/${baseNameOf module}") modules
              }
              cp ${test} tests/${baseNameOf test}${optionalLines setup}
              python tests/${baseNameOf test}${optionalLines extra}
              touch $out
            '';
          pythonScriptCheck = pythonScriptCheckWith { };

          # Every store-path interpolation stays inside an optionalString guard so
          # that removing the package fails inside the builder with the message
          # below, rather than aborting evaluation with a null coercion error.
          assertUserPackage =
            {
              pname,
              executables,
              desktopEntries,
            }:
            entry:
            let
              package = userPackageOf pname entry;
            in
            ''
              ${pkgs.lib.optionalString (package == null) ''
                echo 'missing ${pname} in user packages on ${entry.name}' >&2
                fail=1
              ''}
              ${pkgs.lib.optionalString (package != null) ''
                ${pkgs.lib.concatMapStrings (executable: ''
                  if [ ! -x ${package}/bin/${executable} ]; then
                    echo '${pname} package ships no bin/${executable} executable on ${entry.name}' >&2
                    fail=1
                  fi
                '') executables}
                ${pkgs.lib.concatMapStrings (desktopEntry: ''
                  if [ ! -f ${package}/share/applications/${desktopEntry} ]; then
                    echo '${pname} package ships no ${desktopEntry} entry on ${entry.name}' >&2
                    fail=1
                  fi
                '') desktopEntries}
              ''}
            '';
        in
        {
          pinentry-card =
            pkgs.runCommand "pinentry-card-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.bash
                ];
              }
              ''
                cp ${./scripts/pinentry-card} ./pinentry-card
                bash ${./tests/pinentry-card.sh} ./pinentry-card \
                  ${(import ./packages/gpg-tools.nix { inherit pkgs; }).pinentryCard}/bin/pinentry-card \
                  ${pkgs.pinentry-qt}/bin/pinentry-qt ${pkgs.pinentry-curses}/bin/pinentry-curses \
                  ${pkgs.libsecret}/bin/secret-tool
                touch $out
              '';
          podman-machine-resources = pkgs.runCommand "podman-machine-resources-tests" { } ''
            bash ${./tests/podman-machine-resources.sh} ${
              pkgs.lib.getExe (import ./packages/podman-machine-resources.nix { inherit pkgs; })
            }
            touch $out
          '';
          minikube-darwin-start = pkgs.runCommand "minikube-darwin-start-tests" { } ''
            bash ${./tests/minikube-darwin-start.sh} ${
              pkgs.lib.getExe (import ./packages/minikube-darwin-start.nix { inherit pkgs; })
            }
            touch $out
          '';
          mobile-devices = pkgs.runCommand "mobile-devices-tests" { } ''
            bash ${./tests/mobile-devices.sh} ${
              pkgs.lib.getExe (import ./packages/mobile-devices.nix { inherit pkgs; })
            }
            touch $out
          '';
          darwin-config = import ./tests/darwin-config.nix {
            inherit
              pkgs
              self
              linuxFixtures
              darwinFixtures
              ;
          };
          pinentry-card-darwin =
            pkgs.runCommand "pinentry-card-darwin-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.bash
                ];
              }
              ''
                bash ${./tests/pinentry-card-darwin.sh} ${
                  (import ./packages/gpg-tools.nix { inherit pkgs; }).mkDarwinPinentryCard {
                    pinentryMac = "/pinentry-mac-stand-in/bin/pinentry-mac";
                  }
                }
                touch $out
              '';
          restore-age-identity =
            pythonScriptCheckWith
              {
                nativeBuildInputs = [ pkgs.age ];
              }
              "restore-age-identity"
              "${(import ./packages/gpg-tools.nix { inherit pkgs; }).restoreAgeIdentity}/bin/restore-age-identity"
              ./tests/restore-age-identity.py;
          boot-layout-invariants = import ./tests/boot-layout-invariants.nix { inherit pkgs; };
          claude = import ./tests/claude.nix { inherit pkgs self; };
          retire-orca = import ./tests/retire-orca.nix { inherit pkgs self; };
          codex = import ./tests/codex.nix { inherit pkgs self; };
          omp-settings = import ./tests/omp-settings.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          omp-models-load = import ./tests/omp-models-load.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          omp-acp = import ./tests/omp-acp.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          codex-settings = import ./tests/codex-settings.nix { inherit pkgs self; };
          cargo-settings = import ./tests/cargo-settings.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          synthetic-models = import ./tests/synthetic-models.nix { inherit pkgs; };
          # The probe needs a signed-in instance home, so no check runs it;
          # this covers its rule verdicts and the cleanup of what it plants.
          serve-html = pythonScriptCheck "serve-html" ./scripts/serve-html ./tests/test_serve_html.py;
          agent-settings =
            let
              tools = import ./packages/agent-tools.nix { inherit pkgs; };
              inherit (tools) agentSettingsPython;
              packaged = tools.agentSettings;
            in
            pkgs.runCommand "agent-settings-tests" { nativeBuildInputs = [ agentSettingsPython ]; } ''
              export PYTHONDONTWRITEBYTECODE=1
              mkdir -p scripts tests
              cp ${./scripts/agent-settings} scripts/agent-settings
              cp ${./tests/test_agent_settings.py} tests/test_agent_settings.py
              python tests/test_agent_settings.py

              # Activation runs the packaged binary, not this source copy, and its
              # unit's PATH carries no python3. Exercise the built file so a lost
              # +x bit or an unpatched `#!/usr/bin/env python3` fails here rather
              # than at activation.
              interpreter=$(head -1 ${packaged}/bin/agent-settings)
              case "$interpreter" in
                '#!'/nix/store/*) ;;
                *)
                  echo "packaged merger must carry a store interpreter, got: $interpreter" >&2
                  exit 1
                  ;;
              esac

              # TOML mode through the packaged binary, which proves the built
              # interpreter carries tomlkit: a comment and a table the merge does
              # not own must survive, and the declared leaves start divergent.
              mkdir -p home/.codex
              printf '# keep me\ncheck_for_update_on_startup = true\ndeveloper_instructions = "stale"\n\n[features]\nmemories = true\n\n[plugins."x"]\nenabled = true\n' \
                > home/.codex/config.toml
              printf '{"remove":["developer_instructions"],"setPaths":[{"path":["check_for_update_on_startup"],"value":false},{"path":["features","memories"],"value":false},{"path":["features","daemon_auto_start"],"value":false}]}\n' \
                > codex.json
              env -i ${packaged}/bin/agent-settings --format toml --label Codex \
                --settings "$PWD/home/.codex/config.toml" --declared "$PWD/codex.json"
              grep -qxF '# keep me' home/.codex/config.toml
              ${pkgs.python3}/bin/python3 - <<'PY'
              import tomllib
              merged = tomllib.load(open('home/.codex/config.toml', 'rb'))
              assert merged == {'check_for_update_on_startup': False, 'features': {'memories': False, 'daemon_auto_start': False}, 'plugins': {'x': {'enabled': True}}}, merged
              PY

              # Malformed TOML must fail the process and leave the file alone.
              printf 'model = "unterminated\n' > home/.codex/config.toml
              if env -i ${packaged}/bin/agent-settings --format toml --label Codex \
                  --settings "$PWD/home/.codex/config.toml" --declared "$PWD/codex.json"; then
                echo "packaged merger accepted malformed TOML" >&2
                exit 1
              fi
              if [ "$(cat home/.codex/config.toml)" != 'model = "unterminated' ]; then
                echo "refused TOML merge still rewrote the settings file" >&2
                exit 1
              fi

              touch $out
            '';
          gemini = import ./tests/gemini.nix { inherit pkgs self; };
          grok = import ./tests/grok.nix { inherit pkgs self; };
          ghq = import ./tests/ghq.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          git-lfs = import ./tests/git-lfs.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          git-trim = import ./tests/git-trim.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          antigravity-acp-path = import ./tests/antigravity-acp-path.nix {
            inherit pkgs;
            pluginSource = inputs.compound-engineering-plugin;
          };
          antigravity-cli-sources = pinnedSources "antigravity-cli-sources" ./packages/antigravity-cli-release.json;
          shell-utilities = import ./tests/shell-utilities.nix { inherit pkgs self; };
          mise-settings = import ./tests/mise-settings.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          nix-cleanup = import ./tests/nix-cleanup.nix { inherit pkgs self; };
          elf-load-segments = import ./tests/elf-load-segments.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          boot-splash = import ./tests/boot-splash.nix { inherit pkgs self; };
          agent-plugins = import ./tests/agent-plugins.nix { inherit pkgs self; };
          antigravity-skills = import ./tests/antigravity-skills.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          korean-skills = import ./tests/korean-skills.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          test-audit-skill = import ./tests/test-audit-skill.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          pinned-skills = import ./tests/pinned-skills.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          agent-instructions = import ./tests/agent-instructions.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          git-cli-repo-flags = import ./tests/git-cli-repo-flags.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          agent-plugin-sync =
            pythonScriptCheck "agent-plugin-sync" ./scripts/agent-plugin-sync
              ./tests/test_agent_plugin_sync.py;
          agent-plugin-release =
            pythonScriptCheck "agent-plugin-release" ./scripts/agent-plugin-release
              ./tests/test_agent_plugin_release.py;
          chatgpt-release = pythonScriptCheckWith {
            nativeBuildInputs = [ pkgs.curl ];
          } "chatgpt-release" ./scripts/chatgpt-release ./tests/test_chatgpt_release.py;
          claude-desktop-release =
            pythonScriptCheck "claude-desktop-release" ./scripts/claude-desktop-release
              ./tests/test_claude_desktop_release.py;
          wifiman-desktop-release =
            pythonScriptCheck "wifiman-desktop-release" ./scripts/wifiman-desktop-release
              ./tests/test_wifiman_desktop_release.py;
          claude-code-release =
            pythonScriptCheck "claude-code-release" ./scripts/claude-code-release
              ./tests/test_claude_code_release.py;
          mise-release = pythonScriptCheck "mise-release" ./scripts/mise-release ./tests/test_mise_release.py;
          codex-release =
            pythonScriptCheck "codex-release" ./scripts/codex-release
              ./tests/test_codex_release.py;
          omp-release = pythonScriptCheck "omp-release" ./scripts/omp-release ./tests/test_omp_release.py;
          grok-build-release =
            pythonScriptCheck "grok-build-release" ./scripts/grok-build-release
              ./tests/test_grok_build_release.py;
          antigravity-cli-release =
            pythonScriptCheck "antigravity-cli-release" ./scripts/antigravity-cli-release
              ./tests/test_antigravity_cli_release.py;
          antigravity-acp-release =
            pythonScriptCheck "antigravity-acp-release" ./scripts/antigravity-acp-release
              ./tests/test_antigravity_acp_release.py;
          # The Claude helper runs against the pinned SDK with real Node, so the
          # check carries both instead of letting that test skip.
          agent-usage =
            (pythonScriptCheckWith {
              nativeBuildInputs = [ pkgs.nodejs_24 ];
              modules = [ ./scripts/agent-usage-claude.mjs ];
              setup = ''
                export NODE_PATH=${import ./packages/claude-agent-sdk.nix { inherit pkgs; }}/lib/node_modules
              '';
            })
              "agent-usage"
              ./scripts/agent-usage
              ./tests/test_agent_usage.py;
          npm-release = pythonScriptCheck "npm-release" ./scripts/npm-release ./tests/test_npm_release.py;
          t3code-release =
            pythonScriptCheck "t3code-release" ./scripts/t3code-release
              ./tests/test_t3code_release.py;
          synthetic-models-watch =
            let
              realSource = pkgs.writeText "synthetic-models.json" (
                builtins.toJSON (import ./home/h82/agents/synthetic-models.nix)
              );
            in
            pythonScriptCheckWith {
              modules = [ ./scripts/catalog_snapshot.py ];
              # The real source must match the snapshot, and the tests read it,
              # never a copy that can drift.
              setup = ''
                mkdir -p tests/fixtures
                cp -r ${./tests/fixtures/synthetic-models} tests/fixtures/synthetic-models
                export SYNTHETIC_MODELS_SOURCE_JSON=${realSource}
              '';
            } "synthetic-models-watch" ./scripts/synthetic-models-watch ./tests/test_synthetic_models_watch.py;
          openrouter-catalog-snapshot =
            pythonScriptCheckWith
              {
                modules = [ ./scripts/catalog_snapshot.py ];
                setup = ''
                  mkdir -p tests/fixtures
                  cp -r ${./tests/fixtures/openrouter-models} tests/fixtures/openrouter-models
                '';
              }
              "openrouter-catalog-snapshot"
              ./scripts/openrouter-catalog-snapshot
              ./tests/test_openrouter_catalog_snapshot.py;
          synthetic-models-reconcile =
            pkgs.runCommand "synthetic-models-reconcile-tests"
              {
                nativeBuildInputs = [
                  pkgs.python3
                  pkgs.jq
                  pkgs.gawk
                ];
              }
              ''
                export PYTHONDONTWRITEBYTECODE=1
                bash ${./tests/synthetic-models-reconcile.sh} \
                  ${./.github/workflows/synthetic-models.yml} \
                  ${agentTools.syntheticModelsWatch}/libexec/synthetic-models-watch/synthetic-models-watch \
                  ${./tests/fixtures/synthetic-models/catalog-2026-10-21.json} \
                  ${pkgs.writeText "synthetic-models.json" (
                    builtins.toJSON (import ./home/h82/agents/synthetic-models.nix)
                  )}
                touch $out
              '';
          # Drives the packaged helper, so a package that lost nokogiri from its
          # interpreter fails here rather than in the update workflow.
          android-sdk-release =
            pkgs.runCommand "android-sdk-release-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
              ''
                export PYTHONDONTWRITEBYTECODE=1
                export ANDROID_SDK_RELEASE=${pkgs.lib.getExe agentTools.androidSdkRelease}
                python ${./tests/test_android_sdk_release.py}
                touch $out
              '';
          android-sdk-repo-parity =
            pkgs.runCommand "android-sdk-repo-parity" { nativeBuildInputs = [ pkgs.python3 ]; }
              ''
                export PYTHONDONTWRITEBYTECODE=1
                export ANDROID_SDK_REPO_PARITY=${./tests/android-sdk-repo-parity.py}
                python ${./tests/test_android_sdk_repo_parity.py}
                python ${./tests/android-sdk-repo-parity.py} \
                  ${./packages/android-sdk-repo.json} \
                  ${pkgs.path}/pkgs/development/mobile/androidenv/repo.json
                touch $out
              '';
          agent-browser-deps = import ./tests/agent-browser-deps.nix { inherit pkgs self; };
          wifi-assertions = import ./tests/wifi-assertions.nix { inherit pkgs inputs; };
          tailscale-single-router =
            let
              # Counted over production configurations: a bootstrap output never
              # joins the tailnet as the router the production host is.
              routers = configurations.withTrait "my.tailscale.advertiseRoutes" (
                config: config.my.tailscale.advertiseRoutes
              );
              advertisers = map (entry: entry.name) (pkgs.lib.filter (entry: !entry.bootstrap) routers.enabled);
            in
            pkgs.runCommand "tailscale-single-router-tests" { } ''
              ${configurations.guard}
              ${routers.guard}
              ${
                if pkgs.lib.length advertisers > 1 then
                  ''
                    echo "more than one host advertises Tailscale subnet routes: ${pkgs.lib.concatStringsSep ", " advertisers}" >&2
                    exit 1
                  ''
                else
                  ""
              }
              touch $out
            '';
          publish-cli-auth =
            pythonScriptCheck "publish-cli-auth" ./scripts/publish-cli-auth
              ./tests/test_publish_cli_auth.py;
          docker-credential-sops =
            pythonScriptCheck "docker-credential-sops" ./scripts/docker-credential-sops
              ./tests/test_docker_credential_sops.py;
          podman-containers = import ./tests/podman-containers.nix { inherit pkgs self; };
          android-sdk = import ./tests/android-sdk.nix { inherit pkgs self; };
          session-variables = import ./tests/session-variables.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          antigravity-profiles = import ./tests/antigravity-profiles.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          serve-html-profiles = import ./tests/serve-html-profiles.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          kubernetes-tools = import ./tests/kubernetes-tools.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          minikube-autostart = import ./tests/minikube-autostart.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          zsh-prezto =
            let
              assertConfiguration =
                entry:
                let
                  homeFiles = entry.user.home-files or null;
                  # A missing file fails inside the builder with its name, rather
                  # than aborting evaluation on a null coercion.
                  assertSource =
                    file: pattern:
                    let
                      source = if homeFiles == null then null else "${homeFiles}/${file}";
                    in
                    if source == null then
                      ''
                        echo 'missing home.file ${file} on ${entry.name}' >&2
                        fail=1
                      ''
                    else
                      ''
                        if [ ! -f ${pkgs.lib.escapeShellArg source} ] || ! grep -q ${pkgs.lib.escapeShellArg pattern} ${pkgs.lib.escapeShellArg source}; then
                          echo ${pkgs.lib.escapeShellArg "${file} does not contain ${pattern} on ${entry.name}"} >&2
                          fail=1
                        fi
                      '';
                  dotzshenv = if homeFiles == null then "/nonexistent/.zshenv" else "${homeFiles}/.zshenv";
                  zshenv = "${entry.user.home.homeDirectory or "/nonexistent"}/.config/zsh/.zshenv";
                in
                ''
                  ${assertSource ".config/zsh/.zpreztorc" "zstyle ':prezto:load' pmodule"}
                  ${assertSource ".config/zsh/.zshenv" "runcoms/zshenv"}
                  ${assertSource ".config/zsh/.zshrc" "runcoms/zshrc"}
                  if [ ! -f ${pkgs.lib.escapeShellArg dotzshenv} ] || ! grep -qF ${pkgs.lib.escapeShellArg "source ${zshenv}"} ${pkgs.lib.escapeShellArg dotzshenv}; then
                    echo ${pkgs.lib.escapeShellArg ".zshenv does not source ${zshenv} on ${entry.name}"} >&2
                    fail=1
                  fi
                '';
            in
            pkgs.runCommand "zsh-prezto-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              ${forEveryUser assertConfiguration}
              touch $out
            '';
          ghostty-font =
            let
              assertConfiguration =
                entry:
                let
                  ghosttyConfig =
                    if entry.user ? home-files then "${entry.user.home-files}/.config/ghostty/config" else null;
                  monospaceFonts = builtins.toJSON entry.config.fonts.fontconfig.defaultFonts.monospace;
                in
                ''
                  ${pkgs.lib.optionalString (ghosttyConfig == null) ''
                    echo 'missing xdg.configFile ghostty/config on ${entry.name}' >&2
                    fail=1
                  ''}
                  ${pkgs.lib.optionalString (ghosttyConfig != null) (
                    pkgs.lib.concatMapStrings
                      (font: ''
                        if [ ! -f ${pkgs.lib.escapeShellArg ghosttyConfig} ] || ! grep -Fxq "font-family = ${font}" ${pkgs.lib.escapeShellArg ghosttyConfig}; then
                          echo 'ghostty config does not set font-family = ${font} on ${entry.name}' >&2
                          fail=1
                        fi
                      '')
                      [
                        "JetBrainsMono Nerd Font"
                        "D2CodingLigature Nerd Font"
                        "D2KodingLigature Nerd Font"
                        "Twitter Color Emoji"
                      ]
                  )}
                  ${pkgs.lib.optionalString (ghosttyConfig != null) ''
                    # Twemoji covers ASCII digits and space, so it must stay
                    # after every text font.
                    if [ "$(grep '^font-family = ' ${ghosttyConfig} | tail -n 1)" != 'font-family = Twitter Color Emoji' ] \
                      || [ "$(grep -cFx 'font-family = Twitter Color Emoji' ${ghosttyConfig})" -ne 1 ]; then
                      echo 'ghostty config does not list Twitter Color Emoji once, last, on ${entry.name}' >&2
                      fail=1
                    fi
                  ''}
                  ${pkgs.lib.concatMapStrings
                    (font: ''
                      if ! echo '${monospaceFonts}' | grep -q "${font}"; then
                        echo 'default monospace fonts do not include ${font} on ${entry.name}' >&2
                        fail=1
                      fi
                    '')
                    [
                      "D2CodingLigature Nerd Font"
                      "D2KodingLigature Nerd Font"
                    ]
                  }
                '';
            in
            pkgs.runCommand "ghostty-font-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              ${forEveryConfiguration assertConfiguration}
              touch $out
            '';
          python3-runtime =
            let
              assertConfiguration =
                entry:
                let
                  profile = entry.user.home.path or null;
                in
                pkgs.lib.concatMapStrings
                  (
                    pname:
                    assertUserPackage {
                      inherit pname;
                      executables = [ pname ];
                      desktopEntries = [ ];
                    } entry
                    + (
                      if profile == null then
                        ''
                          echo 'missing user profile on ${entry.name}' >&2
                          fail=1
                        ''
                      else
                        ''
                          if [ ! -x ${profile}/bin/${pname} ] || ! env -i HOME="$TMPDIR" PATH=${profile}/bin ${profile}/bin/${pname} --version; then
                            echo 'installed ${pname} runtime failed on ${entry.name}' >&2
                            fail=1
                          fi
                        ''
                    )
                  )
                  [
                    "python3"
                    "uv"
                  ];
            in
            pkgs.runCommand "python3-runtime-tests" { } ''
              ${forEveryUser assertConfiguration}
              touch $out
            '';
          gpg-agent-no-cache =
            let
              # A user that relays to a remote agent runs no local one; the
              # gpg-agent-relay VM check covers it.
              assertConfiguration =
                entry: if entry.user.my.gpgAgentRelay.enable or false then "" else assertLocalAgent entry;
              assertLocalAgent =
                entry:
                let
                  homedir = entry.user.programs.gpg.homedir or null;
                  home = entry.user.home.homeDirectory or "";
                  homeFiles = entry.user.home-files or null;
                  gpgAgentConf =
                    if homedir == null || homeFiles == null then
                      null
                    else
                      "${homeFiles}/${pkgs.lib.removePrefix "${home}/" homedir}/gpg-agent.conf";
                in
                ''
                  ${pkgs.lib.optionalString (gpgAgentConf == null) ''
                    echo 'missing gpg-agent.conf on ${entry.name}' >&2
                    fail=1
                  ''}
                  ${pkgs.lib.optionalString (gpgAgentConf != null) ''
                    if [ ! -f ${pkgs.lib.escapeShellArg gpgAgentConf} ] || ! grep -Fxq 'default-cache-ttl 0' ${pkgs.lib.escapeShellArg gpgAgentConf}; then
                      echo 'gpg-agent.conf no longer sets default-cache-ttl 0 on ${entry.name}' >&2
                      fail=1
                    fi
                    if ! grep -Fxq 'max-cache-ttl 0' ${gpgAgentConf}; then
                      echo 'gpg-agent.conf no longer sets max-cache-ttl 0 on ${entry.name}' >&2
                      fail=1
                    fi
                    # Any further cache lifetime, ssh variants included, reintroduces the
                    # agent-side cache the card PIN handling is built on doing without.
                    if grep -E 'cache-ttl' ${gpgAgentConf} | grep -qvE '^[a-z-]*cache-ttl(-ssh)? 0$'; then
                      echo 'gpg-agent.conf sets a non-zero cache lifetime on ${entry.name}' >&2
                      fail=1
                    fi
                  ''}
                '';
            in
            pkgs.runCommand "gpg-agent-no-cache-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              set -x
              ${forEveryUser assertConfiguration}
              touch $out
            '';
          yubikey-fido = import ./tests/yubikey-fido.nix { inherit pkgs self; };
          desktop-packages =
            let
              packages = [
                {
                  pname = "kleopatra";
                  executables = [ "kleopatra" ];
                  desktopEntries = [ "org.kde.kleopatra.desktop" ];
                }
                {
                  pname = "telegram-desktop";
                  executables = [ "Telegram" ];
                  desktopEntries = [ "org.telegram.desktop.desktop" ];
                }
                {
                  pname = "libreoffice";
                  executables = [ "libreoffice" ];
                  desktopEntries = [
                    "writer.desktop"
                    "calc.desktop"
                    "impress.desktop"
                  ];
                }
                {
                  pname = "okular";
                  executables = [ "okular" ];
                  # okularApplication_pdf.desktop is NoDisplay and only proves PDF handling;
                  # org.kde.okular.desktop is the entry the application launcher shows.
                  desktopEntries = [
                    "org.kde.okular.desktop"
                    "okularApplication_pdf.desktop"
                  ];
                }
                {
                  pname = "discord";
                  executables = [ "discord" ];
                  desktopEntries = [ "discord.desktop" ];
                }
              ];
            in
            pkgs.runCommand "desktop-packages-tests" { } ''
              set -x
              ${pkgs.lib.concatMapStrings (spec: forEveryConfiguration (assertUserPackage spec)) packages}
              touch $out
            '';
          claude-desktop =
            let
              assertConfiguration =
                entry:
                let
                  hasKvmGroup = builtins.elem "kvm" entry.config.users.users.h82.extraGroups;
                  hasVhostVsock = builtins.elem "vhost_vsock" entry.config.boot.kernelModules;
                in
                ''
                  ${assertUserPackage {
                    pname = "claude-desktop";
                    executables = [ "claude-desktop" ];
                    desktopEntries = [ "com.anthropic.Claude.desktop" ];
                  } entry}
                  ${pkgs.lib.optionalString (!hasKvmGroup) ''
                    echo 'user h82 missing kvm group on ${entry.name}' >&2
                    fail=1
                  ''}
                  ${pkgs.lib.optionalString (!hasVhostVsock) ''
                    echo 'missing vhost_vsock kernel module on ${entry.name}' >&2
                    fail=1
                  ''}
                '';
            in
            pkgs.runCommand "claude-desktop-tests" { } ''
              set -x
              ${forEveryConfiguration assertConfiguration}
              touch $out
            '';
          chatgpt =
            let
              # No version-pin comparison: the package reads its version from the
              # pin file, so that assertion could only ever hold. The wrapper is
              # read for an ozone flag because upstream marks Wayland
              # experimental; the app must stay on its X11 default. The
              # bundled static binaries are run, because a patched one still
              # exists and is executable.
              assertConfiguration =
                entry:
                let
                  chatgptPkg = userPackageOf "chatgpt" entry;
                in
                ''
                  ${assertUserPackage {
                    pname = "chatgpt";
                    executables = [ "chatgpt" ];
                    desktopEntries = [ "chatgpt.desktop" ];
                  } entry}
                  ${pkgs.lib.optionalString (chatgptPkg != null) ''
                    if grep -q -- 'ozone' ${chatgptPkg}/bin/chatgpt; then
                      echo 'the chatgpt wrapper on ${entry.name} carries an ozone flag' >&2
                      fail=1
                    fi
                    # Exercise the generated environment without starting the GUI.
                    # Replace only the final application target in a temporary copy.
                    python - ${chatgptPkg}/bin/chatgpt "$PWD/chatgpt-probe" "$PWD/chatgpt-record" <<'PY'
                    import pathlib, sys
                    source, probe, recorder = map(pathlib.Path, sys.argv[1:])
                    wrapper = source.read_text()
                    target = '"${chatgptPkg}/lib/chatgpt/ChatGPT"'
                    if wrapper.count(target) != 1:
                        sys.exit("cannot identify the final ChatGPT exec target")
                    probe.write_text(wrapper.replace(target, '"' + str(recorder) + '"'))
                    probe.chmod(0o755)
                    PY
                    cat > chatgpt-record <<'SH'
                    #!${pkgs.runtimeShell}
                    command -v bwrap
                    SH
                    chmod +x chatgpt-record
                    mkdir -p empty-path
                    if ! bwrap=$(PATH="$PWD/empty-path" ./chatgpt-probe) \
                      || [ "$bwrap" != '${pkgs.bubblewrap}/bin/bwrap' ]; then
                      echo 'the chatgpt wrapper on ${entry.name} does not resolve the packaged bwrap' >&2
                      fail=1
                    fi
                    python - ${chatgptPkg}/share/applications/chatgpt.desktop ${chatgptPkg}/bin/chatgpt <<'PY'
                    import configparser, shlex, sys
                    desktop = configparser.ConfigParser(interpolation=None, strict=False)
                    desktop.read(sys.argv[1])
                    command = shlex.split(desktop.get("Desktop Entry", "Exec", fallback=""))
                    if not command or command[0] not in ("chatgpt", sys.argv[2]):
                        sys.exit("ChatGPT desktop entry does not launch bin/chatgpt")
                    PY
                    # Run, not just inspect: autoPatchelf adding a runpath to these
                    # static-pie binaries leaves them segfaulting while every file
                    # still exists.
                    for binary in codex rg; do
                      if ! HOME="$TMPDIR" ${chatgptPkg}/lib/chatgpt/resources/$binary --version > /dev/null 2>&1; then
                        echo "the bundled $binary in chatgpt on ${entry.name} does not run" >&2
                        fail=1
                      fi
                    done
                    if ! HOME="$TMPDIR" ${chatgptPkg}/lib/chatgpt/resources/codex-code-mode-host --help > /dev/null 2>&1; then
                      echo 'the bundled codex-code-mode-host in chatgpt on ${entry.name} does not run' >&2
                      fail=1
                    fi
                  ''}
                '';
            in
            pkgs.runCommand "chatgpt-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
              set -x
              ${forEveryConfiguration assertConfiguration}
              touch $out
            '';
          claude-code =
            let
              # Presence and an executable bin/claude alone would stay green even if
              # the override silently fell back to nixpkgs' own bundled manifest, so
              # this also asserts the package's own version attribute matches this
              # repo's pinned version (AE1). Reading `claudePkg.version` rather than
              # re-invoking `--version` doesn't re-check anything new: nixpkgs'
              # claude-code derivation already runs `versionCheckHook` unconditionally
              # at build time, which fails the build unless the binary's own
              # `--version` output already matches this exact attribute.
              pinnedVersion =
                (builtins.fromJSON (builtins.readFile ./packages/claude-code-manifest.json)).version;
              assertConfiguration =
                entry:
                let
                  claudePkg = userPackageOf "claude-code" entry;
                  versionMismatch =
                    pkgs.lib.optionalString (claudePkg != null && claudePkg.version != pinnedVersion)
                      ''
                        echo "claude-code on ${entry.name} is built from version '${claudePkg.version}', expected pin ${pinnedVersion}" >&2
                        fail=1
                      '';
                in
                ''
                  ${assertUserPackage {
                    pname = "claude-code";
                    executables = [ "claude" ];
                    desktopEntries = [ ];
                  } entry}
                  ${versionMismatch}
                '';
            in
            pkgs.runCommand "claude-code-tests" { } ''
              set -x
              ${forEveryConfiguration assertConfiguration}
              touch $out
            '';
          grok-absent =
            let
              inherit (pkgs) lib;
              isGrokName = name: lib.hasInfix "grok-bot" (lib.toLower name);
              # Names that contain "grok-bot" but are not Grok Bot. None today.
              allowed = [ ];
              grokNamesOf =
                names: lib.unique (builtins.filter (name: isGrokName name && !lib.elem name allowed) names);
              # A package counts by its pname or its name, so a renamed wrapper
              # such as grok-bot-cli is caught as well as grok-bot. Grok Build is
              # installed on purpose and is not matched.
              grokPackagesOf =
                packages:
                grokNamesOf (
                  lib.concatMap (p: [
                    (p.pname or "")
                    (p.name or "")
                  ]) packages
                );
              darwinApps = import ./modules/shared/darwin-apps.nix;
              grokApps = grokNamesOf (builtins.attrNames darwinApps.apps);
              report =
                names: message:
                lib.optionalString (names != [ ]) ''
                  echo ${lib.escapeShellArg "${message}: ${toString names}"} >&2
                  fail=1
                '';
              assertUser = entry: ''
                ${report (grokPackagesOf (userPackagesOf entry)) "Grok Bot packages are still in the user packages on ${entry.name}"}
              '';
              assertNixos = entry: ''
                ${report (grokPackagesOf (
                  entry.config.environment.systemPackages or [ ]
                )) "Grok Bot packages are still in environment.systemPackages on ${entry.name}"}
                ${report (grokNamesOf (
                  builtins.attrNames (entry.config.systemd.services or { })
                )) "${entry.name} still has Grok Bot system units"}
                ${report (grokNamesOf (
                  builtins.attrNames (entry.config.systemd.user.services or { })
                )) "${entry.name} still has Grok Bot user units"}
              '';
              assertFixture =
                fixture:
                let
                  smConfig = fixture.host.systemManager.config;
                in
                ''
                  ${report (grokNamesOf (builtins.attrNames smConfig.environment.etc)) "the system-manager configuration of ${fixture.name} still writes /etc files for Grok Bot"}
                  ${report (grokNamesOf (builtins.attrNames smConfig.systemd.services)) "the system-manager configuration of ${fixture.name} still has Grok Bot units"}
                '';
              # Real Mac hosts and the macOS fixtures alike, read from the
              # evaluated configuration, so a cask, App Store app, or package a
              # module adds outside modules/shared/darwin-apps.nix is caught too.
              darwinEntries =
                map (entry: { inherit (entry) name host; }) darwinFixtures
                ++ lib.mapAttrsToList (name: host: { inherit name host; }) self.darwinConfigurations;
              assertDarwin =
                entry:
                let
                  inherit (entry.host) config;
                  user = config.home-manager.users.${config.my.user.name} or { };
                in
                ''
                  ${report (grokNamesOf (
                    map (cask: cask.name) config.homebrew.casks
                  )) "the macOS casks of ${entry.name} still include Grok Bot"}
                  ${report (grokNamesOf (builtins.attrNames config.homebrew.masApps)) "the App Store apps of ${entry.name} still include Grok Bot"}
                  ${report (grokPackagesOf (
                    config.environment.systemPackages or [ ]
                  )) "Grok Bot packages are still in environment.systemPackages on ${entry.name}"}
                  ${assertUser {
                    inherit (entry) name;
                    inherit user;
                  }}
                '';
              standaloneUsers = lib.mapAttrsToList (name: home: {
                inherit name;
                user = home.config;
              }) self.homeConfigurations;
            in
            pkgs.runCommand "grok-absent" { } ''
              ${configurations.userGuard}
              fail=0
              ${lib.concatMapStrings assertUser (configurations.userEntries ++ standaloneUsers)}
              ${lib.concatMapStrings assertNixos configurations.entries}
              ${lib.optionalString (configurations.linuxFixtures == [ ]) ''
                echo 'no non-NixOS fixture host of this architecture, so the system-manager side of this check would cover none' >&2
                fail=1
              ''}
              ${lib.concatMapStrings assertFixture configurations.linuxFixtures}
              ${lib.optionalString (darwinFixtures == [ ]) ''
                echo 'no macOS fixture host, so the evaluated-cask side of this check would cover none' >&2
                fail=1
              ''}
              ${lib.concatMapStrings assertDarwin darwinEntries}
              ${report grokApps "modules/shared/darwin-apps.nix still maps Grok Bot apps"}
              [ "$fail" = 0 ] || exit 1
              touch $out
            '';
          t3code =
            let
              # Package-only: the derivations come straight from this flake's
              # outputs, so neither can be null and no interpolation needs a
              # guard. The binaries are run, not just inspected, because a
              # stripped SEA or a patched static-pie binary still exists and is
              # executable. The pinned version is read from the pin file, so a
              # binary that reports any other version fails.
              pinnedVersion = (builtins.fromJSON (builtins.readFile ./packages/t3code-release.json)).version;
              cli = self.packages.${system}.t3code-cli;
              desktop = self.packages.${system}.t3code;
              tree = "${cli}/libexec/t3code";
              fakeRuntimeDir = "/run/user/4242";
              ptyProbe = pkgs.writeText "t3code-pty-probe.cjs" ''
                const pty = require(process.env.T3CODE_TREE + "/node_modules/node-pty");
                let output = "";
                const child = pty.spawn("${pkgs.coreutils}/bin/echo", ["pty", "spawned"], {});
                child.onData((data) => { output += data; });
                child.onExit(({ exitCode }) => {
                  console.log("pty-probe exit=" + exitCode + " output=" + output.trim());
                });
              '';
            in
            pkgs.runCommand "t3code-tests" { } ''
              set -x
              fail=0
              export HOME="$TMPDIR"

              if ! version=$(${cli}/bin/t3 --version 2>&1); then
                echo "t3 --version fails: $version" >&2
                fail=1
              elif [ "$version" != "t3 v${pinnedVersion}" ]; then
                echo "t3 --version reports '$version', expected the pin ${pinnedVersion}" >&2
                fail=1
              fi

              # The SEA honours NODE_OPTIONS, so node-pty's native addon is
              # loaded by the patched binary itself and spawns a real pty.
              probe=$(T3CODE_TREE=${tree} NODE_OPTIONS="--require ${ptyProbe}" ${cli}/bin/t3 --version 2>&1) || true
              case $probe in
                *"pty-probe exit=0 output=pty spawned"*) ;;
                *)
                  echo "node-pty does not load and spawn from the t3code-cli tree: $probe" >&2
                  fail=1
                  ;;
              esac

              rg=${tree}/node_modules/@cursor/sdk-${cli.platformKey}/bin/rg
              if ! "$rg" --version > /dev/null 2>&1; then
                echo "the bundled static-pie rg in t3code-cli does not run" >&2
                fail=1
              fi

              monitor=${tree}/resource-monitor/${cli.platformKey}/t3-resource-monitor
              if ! timeout 10 "$monitor" < /dev/null > monitor.out 2>&1 \
                || ! grep -q '"type":"hello"' monitor.out; then
                echo "the bundled t3-resource-monitor does not run" >&2
                cat monitor.out >&2
                fail=1
              fi

              # Takes the literal value and escapes it for the extended regex.
              expect_setenv() {
                value=$(printf '%s' "$2" | sed 's/[].[*^$+?(){}|\\]/\\&/g')
                if ! grep -qE "^[[:space:]]*--setenv $1 $value( |\$)" ${desktop}/bin/t3code-desktop; then
                  echo "the t3code-desktop wrapper does not set $1 to $2" >&2
                  fail=1
                fi
              }
              expect_setenv T3CODE_DISABLE_AUTO_UPDATE 1
              expect_setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt

              # Expanded under a fake runtime directory, so a path baked in at
              # build time cannot match.
              containerHost=$(
                XDG_RUNTIME_DIR=${fakeRuntimeDir}
                line=$(grep -E '^[[:space:]]*--setenv CONTAINER_HOST ' ${desktop}/bin/t3code-desktop) || exit 0
                eval "set -- $line"
                printf '%s' "$3"
              )
              if [ "$containerHost" != "unix://${fakeRuntimeDir}/podman/podman.sock" ]; then
                echo "t3code-desktop sandbox CONTAINER_HOST '$containerHost' is not the session Podman socket" >&2
                fail=1
              fi

              entry=${desktop}/share/applications/t3code.desktop
              if [ ! -f "$entry" ]; then
                echo "t3code-desktop ships no t3code.desktop entry" >&2
                fail=1
              else
                exec=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$entry")
                if [ -z "$exec" ] || [ ! -x "${desktop}/bin/$exec" ]; then
                  echo "t3code.desktop Exec '$exec' names no binary in the t3code-desktop package" >&2
                  fail=1
                fi
              fi

              [ "$fail" = 0 ] || exit 1
              touch $out
            '';
          bootstrap-recipients = import ./tests/bootstrap-recipients.nix { inherit pkgs; };
          linux-host-secrets = import ./tests/linux-host-secrets.nix { inherit pkgs self; };
          sops-recipients = import ./tests/sops-recipients.nix { inherit pkgs self; };
          update-dependencies-reconcile =
            pkgs.runCommand "update-dependencies-reconcile-tests"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.jq
                  pkgs.yq-go
                  pkgs.gawk
                ];
              }
              ''
                export HOME=$TMPDIR
                bash ${./tests/update-dependencies-reconcile.sh} \
                  ${./.github/workflows/update-dependencies.yml} \
                  ${./.gitignore}
                touch $out
              '';
          model-catalogs-reconcile =
            pkgs.runCommand "model-catalogs-reconcile-tests"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.jq
                  pkgs.yq-go
                  pkgs.gawk
                ];
              }
              ''
                export HOME=$TMPDIR
                bash ${./tests/model-catalogs-reconcile.sh} \
                  ${./.github/workflows/model-catalogs.yml}
                touch $out
              '';
          ci-workflow-docs-skip =
            pkgs.runCommand "ci-workflow-docs-skip-tests"
              {
                nativeBuildInputs = [
                  pkgs.gnugrep
                  (pkgs.python3.withPackages (p: [ p.pyyaml ]))
                  pkgs.nix
                ];
              }
              ''
                bash ${./tests/check-workflow-docs-skip.sh} ${./.github/workflows/check.yml}
                touch $out
              '';
          desktop-autostart = import ./tests/desktop-autostart.nix { inherit pkgs self; };
          desktop-ssh = import ./tests/desktop-ssh.nix { inherit pkgs self; };
          plasma-taskbar = import ./tests/plasma-taskbar.nix { inherit pkgs self; };
          kde-theme = import ./tests/kde-theme.nix { inherit pkgs self; };
          baloo-extractor = import ./tests/baloo-extractor.nix { inherit pkgs self; };
          emoji-font = import ./tests/emoji-font.nix { inherit pkgs self; };
          user-avatar = import ./tests/user-avatar.nix { inherit pkgs self; };
          udev-device-access = import ./tests/udev-device-access.nix { inherit pkgs self; };
          ssh-server = import ./tests/ssh-server.nix { inherit pkgs self; };
          kernel-sysctl = import ./tests/kernel-sysctl.nix { inherit pkgs self; };
          proton-vpn = import ./tests/proton-vpn.nix { inherit pkgs self; };
          printing = import ./tests/printing.nix { inherit pkgs self; };
          winbox = import ./tests/winbox.nix { inherit pkgs self; };
          wifiman = import ./tests/wifiman.nix { inherit pkgs self; };
          host-name-guard = import ./tests/host-name-guard.nix { inherit pkgs self; };
          vm-checks-guard = import ./tests/vm-checks-guard.nix {
            inherit pkgs vmChecks;
            # removeAttrs does not force the removed value, so the guard never
            # evaluates itself.
            checks = builtins.removeAttrs self.checks.${system} [ "vm-checks-guard" ];
          };
          check-shards-guard = import ./tests/check-shards-guard.nix {
            inherit pkgs;
            # attrNames forces no check, so the guard never evaluates itself.
            checkNames = builtins.attrNames self.checks.${system};
            inherit (checkShards) members;
          };
          host-options = import ./tests/host-options.nix { inherit pkgs self; };
          host-secrets = import ./tests/host-secrets.nix { inherit pkgs; };
          tls-inspection-ca = import ./tests/tls-inspection-ca.nix { inherit pkgs; };
          network-recovery = import ./tests/network-recovery.nix { inherit pkgs; };
          inherit (import ./tests/non-nixos-scripts.nix { inherit pkgs; })
            install-user-age-identity
            nr-linux
            nr-darwin
            ;
          nr = import ./tests/nr.nix { inherit pkgs self; };
          agent-api-key-secrets = import ./tests/agent-api-key-secrets.nix { inherit pkgs self; };
          text-template = import ./tests/text-template.nix { inherit pkgs; };
          tokscale = import ./tests/tokscale.nix { inherit pkgs self; };
          vscodium = import ./tests/vscodium.nix { inherit pkgs self; };
          tokscale-wrapper =
            let
              packaged = import ./packages/tokscale.nix {
                inherit pkgs;
                hostName = "test-host";
                tokenFile = "${pkgs.writeText "tokscale-fake-token" "fake-token-123\n"}";
              };
            in
            pkgs.runCommand "tokscale-wrapper-tests" { } ''
              export HOME=$TMPDIR
              mkdir -p scripts tests
              cp ${./scripts/tokscale} scripts/tokscale
              cp ${./tests/tokscale.sh} tests/tokscale.sh
              chmod +x scripts/tokscale
              patchShebangs scripts/tokscale
              bash tests/tokscale.sh scripts/tokscale
              bash tests/tokscale.sh --packaged ${packaged}/bin/tokscale test-host fake-token-123
              touch $out
            '';
          lint-staged-markdown =
            let
              miseToml = builtins.fromTOML (builtins.readFile ./mise.toml);
              miseLock = builtins.fromTOML (builtins.readFile ./mise.lock);
              tomlVersion = miseToml.tools."npm:markdownlint-cli2";
              lockVersion = (builtins.head miseLock.tools."npm:markdownlint-cli2").version;
              nixpkgsVersion = pkgs.markdownlint-cli2.version;
              taskRun = miseToml.tasks."lint-staged-markdown".run;
            in
            pkgs.runCommand "lint-staged-markdown-tests"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.git
                  pkgs.markdownlint-cli2
                ];
              }
              ''
                export HOME=$TMPDIR
                mkdir -p scripts tests .githooks
                cp ${./scripts/lint-staged-markdown} scripts/lint-staged-markdown
                cp ${./tests/lint-staged-markdown.sh} tests/lint-staged-markdown.sh
                cp ${./.githooks/pre-commit} .githooks/pre-commit
                cp ${./.markdownlint-cli2.jsonc} .markdownlint-cli2.jsonc
                chmod +x scripts/lint-staged-markdown .githooks/pre-commit
                patchShebangs scripts/lint-staged-markdown .githooks/pre-commit tests/lint-staged-markdown.sh

                bash tests/lint-staged-markdown.sh scripts/lint-staged-markdown .githooks/pre-commit .markdownlint-cli2.jsonc "${tomlVersion}" "${lockVersion}" "${nixpkgsVersion}" "${taskRun}"
                touch $out
              '';
          ci-docs-only-paths =
            pkgs.runCommand "ci-docs-only-paths-tests" { nativeBuildInputs = [ pkgs.bash ]; }
              ''
                mkdir -p scripts tests
                cp ${./scripts/ci-docs-only-paths} scripts/ci-docs-only-paths
                cp ${./tests/ci-docs-only-paths.sh} tests/ci-docs-only-paths.sh
                chmod +x scripts/ci-docs-only-paths
                patchShebangs scripts/ci-docs-only-paths
                bash tests/ci-docs-only-paths.sh scripts/ci-docs-only-paths
                touch $out
              '';
          markdown-lint =
            pkgs.runCommand "markdown-lint-tests" { nativeBuildInputs = [ pkgs.markdownlint-cli2 ]; }
              ''
                export HOME=$TMPDIR
                cd ${self}
                markdownlint-cli2
                touch $out
              '';
          age-identity-helpers =
            pkgs.runCommand "age-identity-helpers-tests" { nativeBuildInputs = [ pkgs.coreutils ]; }
              ''
                export HOME=$TMPDIR
                mkdir -p scripts tests
                cp ${./scripts/recover-age-identity} scripts/recover-age-identity
                cp ${./scripts/prepare-age-identity} scripts/prepare-age-identity
                cp ${./tests/age-identity-helpers.sh} tests/age-identity-helpers.sh
                chmod +x scripts/recover-age-identity scripts/prepare-age-identity
                patchShebangs scripts/recover-age-identity scripts/prepare-age-identity
                bash tests/age-identity-helpers.sh \
                  scripts/recover-age-identity scripts/prepare-age-identity
                touch $out
              '';
          non-nixos-outputs = import ./tests/non-nixos-outputs.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
          t3code-traits = import ./tests/t3code-traits.nix {
            inherit pkgs self;
            fixtures = linuxFixtures;
          };
        }
        // fixtureChecksFor system;
      formatter.${system} = pkgs.nixfmt-tree;
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          age
          sops
          gnupg
          git
          nixfmt
          libsecret
          shellcheck
          python3
          yubikey-manager
        ];
      };
    };
}
