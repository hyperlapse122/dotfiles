{
  config,
  lib,
  pkgs,
  ...
}:
let
  ollama = if config.my.cuda.enable then pkgs.ollama-cuda else pkgs.ollama;
  provision = import ../../../packages/ollama-provision.nix {
    inherit pkgs;
    kind = "nixos";
  };
in
{
  config = lib.mkIf (!config.my.bootstrap) {
    users.users.${config.my.user.name}.linger = true;
    environment.systemPackages = [ ollama ];

    systemd.user.services.ollama = {
      description = "Local Ollama server";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = config.my.user.name;
      environment = {
        OLLAMA_HOST = "127.0.0.1:11434";
        OLLAMA_NO_CLOUD = "1";
      };
      serviceConfig = {
        ExecStart = "${lib.getExe ollama} serve";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.ollama-provision = {
      description = "Provision the local Pi model";
      wantedBy = [ "default.target" ];
      after = [ "ollama.service" ];
      unitConfig = {
        ConditionUser = config.my.user.name;
        # A model pull can take minutes; default.target must not wait for it.
        DefaultDependencies = false;
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe provision;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };
  };
}
