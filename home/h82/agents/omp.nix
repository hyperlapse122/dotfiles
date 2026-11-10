{
  config,
  lib,
  pkgs,
  ...
}:
let
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
  catalogs = import ./omp-model-catalogs.nix;
  keyDirectory =
    if config.my.kind != "nixos" then config.my.secrets.stateDir else "/run/secrets/cli-auth";
  omp = import ../../../packages/omp.nix {
    inherit pkgs;
    syntheticKeyFile = "${keyDirectory}/synthetic_api_key";
    openrouterKeyFile = "${keyDirectory}/openrouter_api_key";
  };
  roles = import ./omp-roles.nix;
  fff = import ./fff-server.nix { inherit pkgs; };
  documents = config.my.omp.documents;
  declared = pkgs.writeText "omp-common-documents.json" (
    builtins.toJSON (lib.mapAttrs (_: path: toString path) documents)
  );
in
{
  options.my.omp = {
    skillDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Complete plugin skill trees discovered by native OMP.";
    };
    documents = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      description = "Complete common OMP documents restored on apply; state stays writable and separate.";
    };
    declaration = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Manifest shared by Home Manager and NixOS activation.";
    };
  };

  config = {
    my.omp.declaration = declared;
    my.omp.documents = {
      "config.yml" = lib.mkDefault (
        pkgs.writeText "omp-config.json" (
          builtins.toJSON {
            memory.backend = "off";
            autolearn.enabled = false;
            inherit (catalogs) disabledProviders;
            enabledModels = catalogs.patterns;
            startup.checkUpdate = false;
            marketplace.autoUpdate = "off";
            inherit (roles)
              defaultThinkingLevel
              github
              modelRoles
              task
              ;
            skills.customDirectories = config.my.omp.skillDirectories;
            symbolPreset = "nerd";
            composer.shape = "band";
            theme = {
              dark = "titanium";
              light = "light";
            };
            setupVersion = 2;
            tui = {
              resizeScrollback = "rebuild";
              completeScrollback = true;
              textSizing = true;
              codexResetFireworks = true;
              mouse = false;
              imeSafeCursor = true;
            };
            terminal.showProgress = true;
            display = {
              subagentLivePreview = true;
              shimmer = "kitt";
              showTokenUsage = true;
              showTurnTime = true;
            };
          }
        )
      );
      "models.yml" = lib.mkDefault (import ./omp-declarations.nix { inherit pkgs omp; });
      # Restored whole on apply, so a server added by hand lasts only until
      # the next apply; the reconciler keeps a declared server's auth. OMP in
      # ACP mode, as T3 Code runs it, ignores this file and connects only the
      # servers the client sends in session/new.
      "mcp.json" = lib.mkDefault (
        pkgs.writeText "omp-mcp.json" (
          builtins.toJSON {
            mcpServers.fff = {
              type = "stdio";
              inherit (fff) command args;
            };
          }
        )
      );
    };

    home.packages = [
      omp
      (import ../../../packages/acpx.nix { inherit pkgs; })
    ];
    home.file.".omp/agent/agents/architect.md".source = ./omp-architect.md;
    home.file.".omp/agent/agents/writer.md".source = ./omp-writer.md;
    home.file.".omp/agent/agents/designer.md".source = ./omp-designer.md;
    # These documents stay regular writable files: OMP's settings UI can edit
    # them between applies. Direct activation runs on every non-NixOS apply;
    # the system hook covers NixOS even when its home generation is unchanged.
    home.activation.ompSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
      ${tools.ompConfigReconcile}/bin/omp-config-reconcile \
        --agent-dir ${lib.escapeShellArg "${config.home.homeDirectory}/.omp/agent"} \
        --declared ${declared} ''${DRY_RUN+--dry-run}
    '';
  };
}
