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

  # A symlink in bin keeps the script beside its Python import in libexec.
  helperWithModule =
    module: name: src:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.python3 ];
      installPhase = ''
        install -Dm755 ${src} $out/libexec/${name}/${name}
        install -Dm644 ${module} $out/libexec/${name}/${baseNameOf module}
        patchShebangs $out/libexec/${name}/${name}
        mkdir -p $out/bin
        ln -s ../libexec/${name}/${name} $out/bin/${name}
      '';
      meta.mainProgram = name;
    };

  catalogHelper = helperWithModule ../scripts/catalog_snapshot.py;
  releaseHelper = helperWithModule ../scripts/release_pin.py;

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
  claudeCodeRelease = releaseHelper "claude-code-release" ../scripts/claude-code-release;

  # Resolves the latest mise release from the SHASUMS256.txt asset of its
  # latest GitHub release.
  miseRelease = releaseHelper "mise-release" ../scripts/mise-release;

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

  piRelease = releaseHelper "pi-release" ../scripts/pi-release;

  codexRelease = releaseHelper "codex-release" ../scripts/codex-release;

  # Resolves the newest stable OpenCode v2 release from the GitHub release list.
  opencodeRelease = releaseHelper "opencode-release" ../scripts/opencode-release;

  # Seeds OpenCode's credential store from the published API key files.
  opencodeAuthSync = pythonHelper "opencode-auth-sync" ../scripts/opencode-auth-sync;

  # Seeds omp's credential store from the published API key files.
  ompAuthSync = pythonHelper "omp-auth-sync" ../scripts/omp-auth-sync;

  # Names the provider and model that served an OpenCode session, from
  # OpenCode's own session record, for T3 cross-model evidence.
  opencodeServingModel = pythonHelper "opencode-serving-model" ../scripts/opencode-serving-model;

  # Resolves the latest release of an npm package that ships no lock file,
  # such as acpx, and regenerates its lock file and npmDepsHash.
  # npm and prefetch-npm-deps come from the store so the update workflow's
  # runner needs neither.
  npmRelease = pkgs.symlinkJoin {
    name = "npm-release";
    paths = [ (releaseHelper "npm-release" ../scripts/npm-release) ];
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

  # Rewrites the committed OpenAI and Anthropic model lists that Pi and
  # OpenCode declare, from each provider's model list and models.dev.
  providerModelsWatch = catalogHelper "provider-models-watch" ../scripts/provider-models-watch;

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
    miseRelease
    preztoRelease
    piRelease
    codexRelease
    opencodeRelease
    opencodeAuthSync
    ompAuthSync
    opencodeServingModel
    npmRelease
    t3codeRelease
    syntheticModelsWatch
    opencodeGoModelsWatch
    providerModelsWatch
    androidSdkRelease
    serveHtml
    ;
}
