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
    openai = "openai_api_key";
    anthropic = "anthropic_api_key";
    opencode-go = "opencode_go_api_key";
    exa = "exa_api_key";
  };
in
{
  imports = [ inputs.omp.homeManagerModules.default ];

  programs.omp = {
    enable = true;
    settings = {
      modelRoles.default = "synthetic/hf:zai-org/GLM-5.3-Flash";
      composer.shape = "band";
      composer.tokenRate = true;
      theme.dark = "titanium";
      theme.light = "light";
      update.auto = false;
      symbolPreset = "nerd";
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
