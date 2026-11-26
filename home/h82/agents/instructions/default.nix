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
  legacyGuides = [
    ".local/share/nix-config/agent-instructions/task-guide.md"
    ".local/share/nix-config/agent-instructions/t3-guide.md"
  ];
  legacyGuideDirectory = ".local/share/nix-config/agent-instructions";
  homeManagerFilePattern = "${builtins.storeDir}/*-home-manager-files/*";

in
{
  home.file = {
    ".local/share/nix-config/refresh-agent-instructions".source = refresh;
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

  home.activation.legacyInstructionGuides = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${lib.concatMapStrings (path: ''
        if [[ -L "$HOME/${path}" && "$(readlink "$HOME/${path}")" == ${homeManagerFilePattern} ]]; then
          rm -f "$HOME/${path}"
        fi
      '') legacyGuides}
      rmdir "$HOME/${legacyGuideDirectory}" 2>/dev/null || :
    fi
  '';
}
