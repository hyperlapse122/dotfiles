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
  openrouterKeyFile =
    if config.my.kind == "darwin" then
      "${config.my.secrets.stateDir}/openrouter_api_key"
    else
      "/run/secrets/cli-auth/openrouter_api_key";
}
