{
  config,
  lib,
  pkgs,
  ...
}:
let
  darwin = config.my.kind == "darwin";
  backend =
    if darwin then
      "mlx"
    else if config.my.cuda.enable then
      "cuda"
    else
      "openrouter";
  keyDirectory = if darwin then config.my.secrets.stateDir else "/run/secrets/cli-auth";
  decide = import ../../../packages/decide.nix {
    inherit pkgs backend;
    openrouterKeyFile = "${keyDirectory}/openrouter_api_key";
  };
  ca =
    if darwin && config.my.tlsInspectionCa.enable && !config.my.bootstrap then
      "/etc/ssl/nix-config/ca-certificates.crt"
    else
      "/etc/ssl/certs/ca-certificates.crt";
  launcher = pkgs.writeShellScript "decide-service" ''
    : "''${SSL_CERT_FILE=${ca}}"
    : "''${REQUESTS_CA_BUNDLE=${ca}}"
    export SSL_CERT_FILE REQUESTS_CA_BUNDLE
    exec ${decide}/bin/decide serve
  '';
in
{
  home.packages = [ decide ];
  systemd.user.services.decide = lib.mkIf (!darwin) {
    Unit.Description = "Decisions service";
    Service = {
      ExecStart = launcher;
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
  launchd.agents.decide = lib.mkIf darwin {
    enable = true;
    config = {
      ProgramArguments = [ "${launcher}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 5;
    };
  };
}
