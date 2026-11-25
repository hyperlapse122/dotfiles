{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  authSync = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).ompAuthSync
  }/bin/omp-auth-sync";
  keyDirectory = config.my.secrets.stateDir;
  providerKeyFiles = {
    synthetic = "synthetic_api_key";
    openrouter = "openrouter_api_key";
    anthropic = "anthropic_api_key";
    opencode-go = "opencode_go_api_key";
    exa = "exa_api_key";
  };
in
{
  imports = [ inputs.omp.homeManagerModules.default ];

  programs.omp = {
    enable = true;
    # The release binary pinned in packages/omp-release.json; the module's
    # default builds omp from source.
    package = import ../../../packages/omp.nix { inherit pkgs; };
    settings = {
      modelRoles = {
        default = "openrouter/deepseek/deepseek-v4.1-flash-1017:max";
        smol = "openrouter/deepseek/deepseek-v4.1-flash-1017:auto";
        slow = "openrouter/anthropic/claude-opus-5.5:medium";
        judge = "ollama/clef-flash:latest";
        dictation = "openrouter/openai/whisper-large-v3";
        speech = "local/phonon-31m";
        image = "openrouter/bytedance-seed/seedream-5-5";
        web = "web/parallel";
      };
      defaultThinkingLevel = "auto";
      composer.shape = "band";
      composer.tokenRate = true;
      theme.dark = "titanium";
      theme.light = "light";
      update.auto = false;
      symbolPreset = "nerd";
      # Records the completed setup wizard; omp reruns the wizard while this
      # is below its own setup version, and the declared file replaces the
      # value omp writes on each switch.
      setupVersion = 3;
    };
  };

  # NixOS runs the same import after SOPS publication, without waiting for
  # Home Manager.
  home.activation.ompAuth = lib.mkIf (config.my.kind == "darwin" && !config.my.bootstrap) (
    lib.hm.dag.entryAfter [ "nixConfigSecretsPublish" "ompConfig" ] ''
      if [[ ! -v DRY_RUN ]]; then
        ${authSync} --omp ${config.programs.omp.package}/bin/omp ${
          lib.escapeShellArgs (
            lib.concatLists (
              lib.mapAttrsToList (provider: file: [
                "--credential"
                "${provider}=${keyDirectory}/${file}"
              ]) providerKeyFiles
            )
          )
        }
      fi
    ''
  );
}
