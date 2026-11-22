{
  config,
  lib,
  pkgs,
  ...
}:
let
  hostFacts = import ../../../../lib/host-facts.nix { inherit lib; };
  renderer = import ../../../../packages/text-template.nix { inherit pkgs; };

  helper = (import ../../../../packages/agent-tools.nix { inherit pkgs; }).agentInstructions;
  context = pkgs.writeText "agent-instructions-context.json" (
    builtins.toJSON (
      (hostFacts.of config.my)
      // {
        locale = {
          name = config.my.locale.name;
          language =
            config.home.sessionVariables.LANGUAGE
              or (if config.my.locale.language != null then config.my.locale.language else config.my.locale.name);
        };
      }
    )
  );
  command = lib.concatStringsSep " " (
    [
      "${helper}/bin/agent-instructions"
      "--context ${context}"
      "--template ${./instructions.md.tmpl}"
      "--renderer ${renderer}/bin/text-template"
    ]
    ++ lib.optional (
      config.my.kind == "nixos"
    ) "--kreadconfig ${pkgs.kdePackages.kconfig}/bin/kreadconfig6"
  );
  refresh = pkgs.writeShellScript "refresh-agent-instructions" ''
    set -eu
    ${lib.optionalString (config.my.kind == "darwin") ''
      export PATH="''${PATH:+$PATH:}/usr/bin:/bin"
    ''}
    ${command} --home "$HOME"
  '';

in
{
  home.file = {
    ".local/share/nix-config/claude-code-agents.json".source =
      ../../../../packages/claude-code-agents.json;
    ".local/share/nix-config/refresh-agent-instructions".source = refresh;
    ".local/share/nix-config/agent-instructions/task-guide.md".source = ./task-guide.md;
    ".local/share/nix-config/agent-instructions/t3-guide.md".source = ./t3-guide.md;
  };

  home.activation.agentInstructions = (
    lib.hm.dag.entryAfter
      ([ "installPackages" ] ++ lib.optional (config.my.kind == "nixos") "kdeSession")
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${refresh}
        fi
      ''
  );
}
