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

  # The two catalog scripts import scripts/catalog_snapshot.py from their own
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
  # Removes the retired Orca app's hooks, status line, and state from a home.
  # tomlkit lets it drop Codex's hook trust entries without rewriting the rest
  # of config.toml.
  retireOrca = helperWith "retire-orca" ../scripts/retire-orca agentSettingsPython;
  agentInstructions =
    (pythonHelper "agent-instructions" ../scripts/agent-instructions).overrideAttrs
      {
        doInstallCheck = true;
        installCheckPhase = ''
          $out/bin/agent-instructions --help >/dev/null
        '';
      };

  ompConfigPython = pkgs.python3.withPackages (ps: [
    ps.pyyaml
    ps.xxhash
  ]);
  ompConfigReconcile =
    helperWith "omp-config-reconcile" ../scripts/omp-config-reconcile
      ompConfigPython;

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

  # Resolves the latest WiFiman Desktop release from Ubiquiti's releases API
  # and hashes its .deb, which upstream publishes no checksum for.
  wifimanDesktopRelease = pythonHelper "wifiman-desktop-release" ../scripts/wifiman-desktop-release;

  # Resolves the latest claude-code release manifest from Anthropic's own
  # release endpoints.
  claudeCodeRelease = pythonHelper "claude-code-release" ../scripts/claude-code-release;

  # Resolves the latest mise release from the SHASUMS256.txt asset of its
  # latest GitHub release.
  miseRelease = pythonHelper "mise-release" ../scripts/mise-release;

  # Resolves the latest Codex release and its musl asset digest from the
  # GitHub releases API.
  codexRelease = pythonHelper "codex-release" ../scripts/codex-release;
  ompRelease = pythonHelper "omp-release" ../scripts/omp-release;

  # Resolves the newest stable Grok Build CLI release and hashes its
  # per-platform binaries, which xAI publishes no checksum for. Its network
  # calls go through overridable commands so the sandboxed repository check
  # can drive it with fixtures.
  grokBuildRelease = pythonHelper "grok-build-release" ../scripts/grok-build-release;

  # Reports every coding-agent provider's usage windows with a shared cache.
  # Its readers call codex, omp, grok, curl and a Node helper on the Claude
  # Agent SDK, so the wrapper puts exactly those on PATH. Home Manager
  # overrides the Synthetic key file per host kind, as omp.nix does. The
  # Antigravity quota service lists Gemini buckets only for a current ACP
  # client, so the wrapper names the pinned ACP runtime's version.
  agentUsage = pkgs.lib.makeOverridable (
    {
      syntheticKeyFile ? "/run/secrets/cli-auth/synthetic_api_key",
    }:
    let
      sdk = import ./claude-agent-sdk.nix { inherit pkgs; };
      omp = import ./omp.nix { inherit pkgs syntheticKeyFile; };
      runtimePath = pkgs.lib.makeBinPath [
        (import ./codex.nix { inherit pkgs; })
        (import ./claude-code.nix { inherit pkgs; })
        (import ./grok-build.nix { inherit pkgs; })
        omp
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
          --set NODE_PATH ${sdk}/lib/node_modules \
          --set AGENT_USAGE_ANTIGRAVITY_VERSION ${(builtins.fromJSON (builtins.readFile ./antigravity-acp-release.json)).version}
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

  # Resolves the latest Antigravity CLI release and its per-platform digests
  # from Google's release feed.
  antigravityCliRelease = pythonHelper "antigravity-cli-release" ../scripts/antigravity-cli-release;

  # Resolves the newest complete Antigravity ACP runtime release by probing
  # candidate versions on Google's download host, and hashes its archives,
  # which upstream publishes no checksum for.
  antigravityAcpRelease = pythonHelper "antigravity-acp-release" ../scripts/antigravity-acp-release;

  # Resolves the newest T3 Code nightly and its asset digests from the GitHub
  # releases API.
  t3codeRelease = pythonHelper "t3code-release" ../scripts/t3code-release;

  # Compares the Synthetic models in home/h82/agents/synthetic-models.nix with
  # Synthetic's catalog, and rewrites the committed Synthetic catalog snapshot.
  syntheticModelsWatch = catalogHelper "synthetic-models-watch" ../scripts/synthetic-models-watch;

  # Rewrites the committed OpenRouter catalog snapshot from OpenRouter's
  # /models/user endpoint.
  openrouterCatalogSnapshot = catalogHelper "openrouter-catalog-snapshot" ../scripts/openrouter-catalog-snapshot;

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
    ompConfigReconcile
    ompConfigPython
    agentPluginSync
    agentPluginRelease
    claudeDesktopRelease
    chatgptRelease
    wifimanDesktopRelease
    claudeCodeRelease
    miseRelease
    codexRelease
    ompRelease
    grokBuildRelease
    agentUsage
    npmRelease
    antigravityCliRelease
    antigravityAcpRelease
    t3codeRelease
    syntheticModelsWatch
    openrouterCatalogSnapshot
    androidSdkRelease
    serveHtml
    retireOrca
    ;
}
