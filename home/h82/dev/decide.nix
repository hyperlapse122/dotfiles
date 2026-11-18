{
  config,
  lib,
  pkgs,
  ...
}:
let
  darwin = config.my.kind == "darwin";
  decide = import ./decide-package.nix { inherit config pkgs; };
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
  programs.zsh.initContent = lib.mkAfter ''
    # Prezto can reuse a completion cache from before decide was installed.
    if (( $+functions[compdef] && ! $+_comps[decide] )); then
      autoload -Uz _decide
      compdef _decide decide
    fi
  '';
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
