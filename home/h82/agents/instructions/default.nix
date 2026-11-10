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
  live = config.my.kind != "linux";
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
  rendered = pkgs.runCommand "agent-instructions" { } ''
    ${command} --home "$out"
  '';
  targets = {
    claude = ".claude/CLAUDE.md";
    codex = ".codex/AGENTS.md";
    omp = ".omp/agent/AGENTS.md";
    # A directory of rule files; recursive linking lets Home Manager prune
    # the files a later render no longer produces.
    antigravity = ".gemini/config/rules";
  };
in
{
  home.file =
    if live then
      { ".local/share/nix-config/refresh-agent-instructions".source = refresh; }
    else
      lib.mapAttrs' (
        delivery: target:
        lib.nameValuePair "agent-instructions-${delivery}" {
          inherit target;
          source = "${rendered}/${target}";
          recursive = delivery == "antigravity";
        }
      ) targets;

  home.activation.agentInstructions = lib.mkIf live (
    lib.hm.dag.entryAfter
      ([ "installPackages" ] ++ lib.optional (config.my.kind == "nixos") "kdeSession")
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${refresh}
        fi
      ''
  );
}
