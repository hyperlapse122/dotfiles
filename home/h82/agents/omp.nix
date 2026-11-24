{ inputs, pkgs, ... }:
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
}
