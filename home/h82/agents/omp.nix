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
        default = "opencode-go/glm-5.3-flash:max";
        smol = "opencode-go/deepseek-v4.1-flash:max";
        slow = "opencode-go/glm-5.3:max";
        judge = "openrouter/cloudflare/clef-flash:auto";
        vision = "opencode-go/kimi-k3.1-pro:auto";
        dictation = "openrouter/openai/whisper-large-v3";
        speech = "local/phonon-31m";
        image = "openrouter/bytedance-seed/seedream-5-5";
        web = "web/parallel";
      };
      defaultThinkingLevel = "auto";
      composer.shape = "band";
      composer.tokenRate = true;
      composer.predictionAlternatives = false;
      theme.dark = "titanium";
      theme.light = "light";
      update.auto = false;
      symbolPreset = "nerd";
      # Records the completed setup wizard; omp reruns the wizard while this
      # is below its own setup version, and the declared file replaces the
      # value omp writes on each switch.
      setupVersion = 3;
      statusLine.sessionAccent = true;
      statusLine.transparent = false;
      terminal.showProgress = false;
      tui.textSizing = true;
      tui.hyperlinks = "auto";
      tui.tight = false;
      tui.imeSafeCursor = true;
      display.shimmer = "kitt";
      display.subagentLivePreview = false;
      title.icons = "boring";
      spelling.autocomplete = "smollm";
      stt.enabled = false;
      startup.checkUpdate = false;
      power.sleepPrevention = "idle";
      compaction.idleEnabled = true;
      ttsr.contextMode = "keep";
      astGrep.enabled = true;
      speechgen.enabled = true;
      generate_image.enabled = true;
      computer.enabled = true;
      github.enabled = true;
      security.enabled = true;
      disassembler.backend = "ghidra";
      todo.reminders = false;
      secrets.enabled = true;
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
