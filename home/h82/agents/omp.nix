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
        default = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017:high";
        smol = "synthetic/hf:openai/gpt-oss-120b:low";
        slow = "synthetic/hf:moonshotai/Kimi-K3.1-Pro:max";
        vision = "synthetic/hf:thinkingmachines/Inkling-2-Mini:low";
        plan = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017:max";
        commit = "synthetic/hf:openai/gpt-oss-120b:low";
        tiny = "synthetic/hf:openai/gpt-oss-120b:low";
        memory = "synthetic/hf:thinkingmachines/Inkling-2-Mini:low";
        task = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017:max";
        advisor = "synthetic/hf:deepseek-ai/DeepSeek-V4.1-Flash-1017:max";
        widget = "synthetic/hf:openai/gpt-oss-120b:low";
        image = "openrouter/bytedance-seed/seedream-5-5";
        web = "web/synthetic";
        speech = "local/phonon-31m";
        dictation = "local/whisper-large-v3-turbo";
        judge = "ollama/clef-flash:latest,synthetic/hf:thinkingmachines/Inkling-2-Mini";
      };
      retry.fallbackChains = {
        image = [ ];
        web = [ ];
        speech = [ ];
        dictation = [ ];
        judge = [ "synthetic/hf:thinkingmachines/Inkling-2-Mini" ];
      };
      mnemopi = {
        embeddingModel = "qwen3-embedding:8b";
        embeddingApiUrl = "http://127.0.0.1:11434/v1";
        embeddingQueryPrefix = "Instruct: Given a question, retrieve stored memories that answer it\nQuery: ";
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
