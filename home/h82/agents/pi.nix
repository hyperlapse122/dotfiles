{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  lock = builtins.fromJSON (builtins.readFile ./pi-model-lock.json);
  catalog = lock.syntheticModelLocks;
  agent = "${config.home.homeDirectory}/.pi/agent";
  keyDirectory =
    if config.my.kind == "nixos" then "/run/secrets/cli-auth" else config.my.secrets.stateDir;
  pi = import ../../../packages/pi.nix {
    inherit pkgs;
    syntheticKeyFile = "${keyDirectory}/synthetic_api_key";
    exaKeyFile = "${keyDirectory}/exa_api_key";
  };
  state = pkgs.writeScriptBin "pi-state" (
    "#!${pkgs.python3}/bin/python3\n"
    + lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile ../../../scripts/pi-state)
  );
in
{
  home.packages = [ pi ];
  home.file.".pi/agent/model-lock.json".source = ./pi-model-lock.json;
  home.file.".pi/agent/dotfiles-policy.ts".source = ./pi-policy.ts;
  home.file.".pi/agent/dotfiles-web.ts".source = ./pi-web.ts;
  home.file.".pi/agent/models.json".text = builtins.toJSON {
    providers.synthetic = {
      inherit (catalog) api baseUrl models;
    };
  };
  home.activation.piSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${pi}/libexec/pi/pi install ${inputs.compound-engineering-plugin}
      ${state}/bin/pi-state --agent ${lib.escapeShellArg agent} --plugin ${inputs.compound-engineering-plugin}
    fi
  '';
  home.activation.piAuth = lib.mkIf (!config.my.bootstrap) (
    lib.hm.dag.entryAfter
      ([ "piSettings" ] ++ lib.optional (config.my.kind == "darwin") "nixConfigSecretsPublish")
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${state}/bin/pi-state --agent ${lib.escapeShellArg agent} --auth-only --key ${lib.escapeShellArg "${keyDirectory}/synthetic_api_key"}
        fi
      ''
  );

}
