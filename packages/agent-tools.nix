{ pkgs }:

let
  # patchShebangs resolves the interpreter from the build PATH, so it has to be
  # here for the `#!/usr/bin/env python3` line to be rewritten into a store
  # path rather than left dangling; a helper that needs libraries passes the
  # interpreter wrapped with them. The source is passed per helper rather than
  # derived from a directory, so a change to one script does not rebuild the
  # others.
  helperWith =
    name: src: interpreter:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ interpreter ];
      installPhase = ''
        install -Dm755 ${src} $out/bin/${name}
        patchShebangs $out/bin/${name}
      '';
      meta.mainProgram = name;
    };

  pythonHelper = name: src: helperWith name src pkgs.python3;

  # The catalog scripts import scripts/catalog_snapshot.py from their own
  # directory, so each is installed beside it under libexec and linked into
  # bin.
  catalogHelper =
    name: src:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.python3 ];
      installPhase = ''
        install -Dm755 ${src} $out/libexec/${name}/${name}
        install -Dm644 ${../scripts/catalog_snapshot.py} $out/libexec/${name}/catalog_snapshot.py
        patchShebangs $out/libexec/${name}/${name}
        mkdir -p $out/bin
        ln -s ../libexec/${name}/${name} $out/bin/${name}
      '';
      meta.mainProgram = name;
    };

  # tomlkit is what lets the TOML mode rewrite a file such as Codex's
  # config.toml without dropping the comments and tables it does not own. The
  # flake check runs the source copy of the tests under this same interpreter.
  agentSettingsPython = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
  agentSettings = helperWith "agent-settings" ../scripts/agent-settings agentSettingsPython;
  agentInstructions =
    (pythonHelper "agent-instructions" ../scripts/agent-instructions).overrideAttrs
      {
        doInstallCheck = true;
        installCheckPhase = ''
          $out/bin/agent-instructions --help >/dev/null
        '';
      };

  # Runs from home activation, where PATH carries neither home.packages nor
  # the login shell's session variables, so the module hands it the agent CLI
  # by store path and exports the declared environment tier around it.
  agentPluginSync = pythonHelper "agent-plugin-sync" ../scripts/agent-plugin-sync;

  # Runs in continuous integration rather than at activation.
  agentPluginRelease = pythonHelper "agent-plugin-release" ../scripts/agent-plugin-release;

  serveHtml = pythonHelper "serve-html" ../scripts/serve-html;

  chatgptRelease = pythonHelper "chatgpt-release" ../scripts/chatgpt-release;

  # Resolves the latest release of Claude Desktop from the Debian APT repository.
  claudeDesktopRelease = pythonHelper "claude-desktop-release" ../scripts/claude-desktop-release;

  # Resolves the latest claude-code release manifest from Anthropic's own
  # release endpoints.
  claudeCodeRelease = pythonHelper "claude-code-release" ../scripts/claude-code-release;

  # Extracts the catalog of subagents built into the Claude Code binary. The
  # wrapper puts the claude-code package built from the current manifest on
  # PATH, so the updater reads exactly the binary a new pin installs.
  claudeCodeAgents =
    (pythonHelper "claude-code-agents" ../scripts/claude-code-agents).overrideAttrs
      (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.makeWrapper ];
        installPhase = old.installPhase + ''
          wrapProgram $out/bin/claude-code-agents \
            --prefix PATH : ${pkgs.lib.makeBinPath [ (import ./claude-code.nix { inherit pkgs; }) ]}
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          $out/bin/claude-code-agents --help >/dev/null
        '';
      });

  harnessAgents =
    harness: repository: manifest:
    let
      pin = builtins.fromJSON (builtins.readFile manifest);
      source = import ./harness-source.nix {
        inherit repository;
        inherit (pin) source;
      };
    in
    pkgs.writeShellScriptBin "${harness}-agents" ''
      exec ${pkgs.python3}/bin/python3 ${../scripts/harness-agents} ${harness} \
        --source ${source} --pin ${manifest} "$@"
    '';

  codexAgents = harnessAgents "codex" "openai/codex" ./codex-release.json;
  piAgents = harnessAgents "pi" "earendil-works/pi" ./pi-release.json;

  # Resolves the latest mise release from the SHASUMS256.txt asset of its
  # latest GitHub release.
  miseRelease = pythonHelper "mise-release" ../scripts/mise-release;

  preztoRelease = (pythonHelper "prezto-release" ../scripts/prezto-release).overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.makeWrapper ];
    installPhase = old.installPhase + ''
      wrapProgram $out/bin/prezto-release \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.gh
            pkgs.curl
          ]
        }
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/prezto-release --help >/dev/null
    '';
  });

  # Resolves the latest Codex release and its musl asset digest from the
  # GitHub releases API.
  piRelease = pythonHelper "pi-release" ../scripts/pi-release;

  codexRelease = pythonHelper "codex-release" ../scripts/codex-release;

  # Resolves the newest stable OpenCode v2 release from the GitHub release list.
  opencodeRelease = pythonHelper "opencode-release" ../scripts/opencode-release;

  # Seeds OpenCode's credential store from the published API key files.
  opencodeAuthSync = pythonHelper "opencode-auth-sync" ../scripts/opencode-auth-sync;

  # Home Manager overrides the Synthetic key file per host kind.
  agentUsage = pkgs.lib.makeOverridable (
    {
      syntheticKeyFile ? "/run/secrets/cli-auth/synthetic_api_key",
    }:
    let
      sdk = import ./claude-agent-sdk.nix { inherit pkgs; };
      runtimePath = pkgs.lib.makeBinPath [
        (import ./codex.nix { inherit pkgs; })
        (import ./claude-code.nix { inherit pkgs; })
        pkgs.nodejs_24
        pkgs.curl
      ];
    in
    (pythonHelper "agent-usage" ../scripts/agent-usage).overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
      installPhase = old.installPhase + ''
        install -Dm644 ${../scripts/agent-usage-claude.mjs} \
          $out/bin/agent-usage-claude.mjs
        wrapProgram $out/bin/agent-usage \
          --prefix PATH : ${runtimePath} \
          --set AGENT_USAGE_SYNTHETIC_KEY_FILE ${pkgs.lib.escapeShellArg syntheticKeyFile} \
          --set NODE_PATH ${sdk}/lib/node_modules
      '';
    })
  ) { };

  # Resolves the latest release of an npm package that ships no lock file,
  # such as acpx, and regenerates its lock file and npmDepsHash.
  # npm and prefetch-npm-deps come from the store so the update workflow's
  # runner needs neither.
  npmRelease = pkgs.symlinkJoin {
    name = "npm-release";
    paths = [ (pythonHelper "npm-release" ../scripts/npm-release) ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/npm-release \
        --prefix PATH : ${
          pkgs.lib.makeBinPath [
            pkgs.nodejs
            pkgs.prefetch-npm-deps
          ]
        }
    '';
    meta.mainProgram = "npm-release";
  };

  t3codeRelease = pythonHelper "t3code-release" ../scripts/t3code-release;

  # Compares the Synthetic models in home/h82/agents/synthetic-models.nix with
  # Synthetic's catalog, and rewrites the committed Synthetic catalog snapshot.
  syntheticModelsWatch = catalogHelper "synthetic-models-watch" ../scripts/synthetic-models-watch;

  # Rewrites the committed OpenCode Go catalog snapshot from Go's public model
  # list.
  opencodeGoModelsWatch = catalogHelper "opencode-go-models-watch" ../scripts/opencode-go-models-watch;

  # Rewrites the committed Pi model-lock snapshots for OpenAI and Anthropic
  # from each provider's model list and Pi's built-in catalog.
  piProviderLocksWatch = catalogHelper "pi-provider-locks-watch" ../scripts/pi-provider-locks-watch;

  # Pins the Android SDK packages from Google's repository XML. It is Ruby
  # because it vendors nixpkgs' androidenv update.rb, which parses with
  # nokogiri.
  androidSdkRelease = helperWith "android-sdk-release" ../scripts/android-sdk-release (
    pkgs.ruby.withPackages (ps: [ ps.nokogiri ])
  );
in
{
  inherit
    agentSettings
    agentInstructions
    agentSettingsPython
    agentPluginSync
    agentPluginRelease
    claudeDesktopRelease
    chatgptRelease
    claudeCodeRelease
    claudeCodeAgents
    codexAgents
    piAgents
    miseRelease
    preztoRelease
    piRelease
    codexRelease
    opencodeRelease
    opencodeAuthSync
    agentUsage
    npmRelease
    t3codeRelease
    syntheticModelsWatch
    opencodeGoModelsWatch
    piProviderLocksWatch
    androidSdkRelease
    serveHtml
    ;
}
