{ pkgs }:
let
  pythonScriptCheckWith =
    {
      setup ? "",
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
      cp ${test} tests/${baseNameOf test}
      ${setup}
      python tests/${baseNameOf test}
      touch $out
    '';
  pythonScriptCheck = pythonScriptCheckWith { };
  releaseScriptCheck = pythonScriptCheckWith { modules = [ ../scripts/release_pin.py ]; };

in
{
  restore-age-identity =
    pythonScriptCheckWith
      {
        nativeBuildInputs = [ pkgs.age ];
      }
      "restore-age-identity"
      "${
        (import ../packages/gpg-tools.nix { inherit pkgs; }).restoreAgeIdentity
      }/bin/restore-age-identity"
      ./restore-age-identity.py;
  serve-html = pythonScriptCheck "serve-html" ../scripts/serve-html ./test_serve_html.py;
  overlay-release =
    pythonScriptCheck "overlay-release" ../scripts/overlay-release
      ./test_overlay_release.py;
  pi-release = releaseScriptCheck "pi-release" ../scripts/pi-release ./test_pi_release.py;
  agent-plugin-sync =
    pythonScriptCheck "agent-plugin-sync" ../scripts/agent-plugin-sync
      ./test_agent_plugin_sync.py;
  agent-plugin-release =
    pythonScriptCheck "agent-plugin-release" ../scripts/agent-plugin-release
      ./test_agent_plugin_release.py;
  chatgpt-release = pythonScriptCheckWith {
    nativeBuildInputs = [ pkgs.curl ];
  } "chatgpt-release" ../scripts/chatgpt-release ./test_chatgpt_release.py;
  claude-desktop-release =
    pythonScriptCheck "claude-desktop-release" ../scripts/claude-desktop-release
      ./test_claude_desktop_release.py;
  claude-code-release =
    releaseScriptCheck "claude-code-release" ../scripts/claude-code-release
      ./test_claude_code_release.py;
  mise-release = releaseScriptCheck "mise-release" ../scripts/mise-release ./test_mise_release.py;
  prezto-release =
    pythonScriptCheck "prezto-release" ../scripts/prezto-release
      ./test_prezto_release.py;
  codex-release = releaseScriptCheck "codex-release" ../scripts/codex-release ./test_codex_release.py;
  opencode-release =
    releaseScriptCheck "opencode-release" ../scripts/opencode-release
      ./test_opencode_release.py;
  opencode-auth-sync =
    pythonScriptCheck "opencode-auth-sync" ../scripts/opencode-auth-sync
      ./test_opencode_auth_sync.py;
  omp-auth-sync = pythonScriptCheck "omp-auth-sync" ../scripts/omp-auth-sync ./test_omp_auth_sync.py;
  opencode-serving-model =
    pythonScriptCheck "opencode-serving-model" ../scripts/opencode-serving-model
      ./test_opencode_serving_model.py;
  npm-release = releaseScriptCheck "npm-release" ../scripts/npm-release ./test_npm_release.py;
  t3code-release =
    pythonScriptCheck "t3code-release" ../scripts/t3code-release
      ./test_t3code_release.py;
  synthetic-models-watch =
    let
      realSource = pkgs.writeText "synthetic-models.json" (
        builtins.toJSON (import ../home/h82/agents/synthetic-models.nix)
      );
    in
    pythonScriptCheckWith {
      modules = [ ../scripts/catalog_snapshot.py ];
      # The real source must match the snapshot, and the tests read it,
      # never a copy that can drift.
      setup = ''
        mkdir -p tests/fixtures
        cp -r ${./fixtures/synthetic-models} tests/fixtures/synthetic-models
        export SYNTHETIC_MODELS_SOURCE_JSON=${realSource}
      '';
    } "synthetic-models-watch" ../scripts/synthetic-models-watch ./test_synthetic_models_watch.py;
  opencode-go-models-watch = pythonScriptCheckWith {
    modules = [ ../scripts/catalog_snapshot.py ];
    setup = ''
      mkdir -p home/h82/agents
      cp ${../home/h82/agents/opencode-go-catalog.json} home/h82/agents/opencode-go-catalog.json
    '';
  } "opencode-go-models-watch" ../scripts/opencode-go-models-watch ./test_opencode_go_models_watch.py;
  provider-models-watch = pythonScriptCheckWith {
    modules = [ ../scripts/catalog_snapshot.py ];
    setup = ''
      mkdir -p home/h82/agents
      cp ${../home/h82/agents/openai-models.json} home/h82/agents/openai-models.json
      cp ${../home/h82/agents/anthropic-models.json} home/h82/agents/anthropic-models.json
    '';
  } "provider-models-watch" ../scripts/provider-models-watch ./test_provider_models_watch.py;
  # Drives the packaged helper, so a package that lost nokogiri from its
  # interpreter fails here rather than in the update workflow.
  publish-cli-auth =
    pythonScriptCheck "publish-cli-auth" ../scripts/publish-cli-auth
      ./test_publish_cli_auth.py;
  docker-credential-sops =
    pythonScriptCheck "docker-credential-sops" ../scripts/docker-credential-sops
      ./test_docker_credential_sops.py;

}
