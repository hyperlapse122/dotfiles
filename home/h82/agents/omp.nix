{ inputs, ... }:
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
}
