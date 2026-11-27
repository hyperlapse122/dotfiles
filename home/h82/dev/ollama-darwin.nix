{
  config,
  lib,
  pkgs,
  ...
}:
let
  merger = lib.getExe (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings;
  declared = pkgs.writeText "ollama-server-settings.json" (
    builtins.toJSON { set.disable_ollama_cloud = true; }
  );
  bootstrap = pkgs.writeShellScript "ollama-app-bootstrap" ''
    marker="$HOME/.local/state/nix-config/ollama-app-launched"
    if [ ! -e "$marker" ]; then
      mkdir -p "$(dirname "$marker")"
      /usr/bin/open -gj -a /Applications/Ollama.app && touch "$marker"
    fi
  '';
in
lib.mkIf (!config.my.bootstrap) {
  home.activation.ollamaSettings =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "installPackages" ]
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${merger} \
            --label Ollama \
            --settings ${lib.escapeShellArg "${config.home.homeDirectory}/.ollama/server.json"} \
            --declared ${declared}
        fi
      '';

  launchd.agents.ollama-bootstrap = {
    enable = true;
    config = {
      ProgramArguments = [ "${bootstrap}" ];
      LimitLoadToSessionType = "Aqua";
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
    };
  };
}
