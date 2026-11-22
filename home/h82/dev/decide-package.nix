{ config, pkgs }:

import ../../../packages/decide.nix {
  inherit pkgs;
  backend =
    if config.my.kind == "darwin" then
      "mlx"
    else if config.my.cuda.enable then
      "cuda"
    else
      "openrouter";
  openrouterKeyFile = "${import ../security/cli-auth-directory.nix config.my}/openrouter_api_key";
}
