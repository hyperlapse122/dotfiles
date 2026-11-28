{
  config,
  lib,
  pkgs,
  ...
}:
let
  ollama = config.services.ollama.package;
in
{
  config = lib.mkIf (!config.my.bootstrap) {
    services.ollama.package = lib.mkDefault (
      import ../../../packages/ollama.nix {
        inherit pkgs;
        cudaSupport = config.my.cuda.enable;
      }
    );
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
  };
}
