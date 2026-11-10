{
  config,
  pkgs,
  lib,
  ...
}:
let
  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";

  # The Antigravity CLI owns ~/.gemini/antigravity-cli/settings.json and
  # rewrites it at runtime -- trusting a workspace replaces the whole file --
  # so a read-only store symlink cannot live there. Activation assigns the
  # declared keys instead and leaves everything the agent wrote alone.
  antigravityTier = {
    disableAutoGenerateMemories = true;
  };

  # Keys this repository used to declare and has since retired. The merge only
  # assigns, so dropping a key from antigravityTier alone would leave its last
  # written value on every machine forever. Move it here instead, and delete
  # the entry once every host has rebuilt past it.
  retiredKeys = [ ];

  cliDeclared = pkgs.writeText "antigravity-declared-settings.json" (
    builtins.toJSON {
      set = antigravityTier;
      remove = retiredKeys;
    }
  );

  # The Antigravity ACP runtime asks for a Google sign-in only when its
  # settings name the personal OAuth flow; Compound Engineering's Antigravity
  # route writes the same value into each run home. The runtime rewrites the
  # file, so activation assigns the key and keeps everything else it wrote.
  acpDeclared = pkgs.writeText "antigravity-acp-declared-settings.json" (
    builtins.toJSON {
      setPaths = [
        {
          path = [
            "auth"
            "type"
          ];
          value = "oauth-personal";
        }
      ];
    }
  );

  # The Antigravity CLI keeps user-scope MCP servers in their own file, the one
  # `agy mcp add` writes, so ownEntries upserts only the declared server. The
  # ACP runtime reads no such file: T3 Code passes its MCP servers per session.
  fff = import ./fff-server.nix { inherit pkgs; };
  mcpDeclared = pkgs.writeText "antigravity-declared-mcp-config.json" (
    builtins.toJSON {
      ownEntries = [
        {
          path = [ "mcpServers" ];
          entries.fff = {
            inherit (fff) command args;
            disabled = false;
          };
        }
      ];
    }
  );
in
{
  my.agents.crossModelPeers = [ "antigravity" ];

  # Disable cross-session, implicit memory for the Gemini and Antigravity CLIs
  # to preserve declarative environment determinism. The Gemini CLI reads this
  # file but does not rewrite it, so it stays a store symlink.
  home.file.".gemini/settings.json".text = builtins.toJSON {
    experimental = {
      autoMemory = false;
    };
  };

  # No executable-existence guard and no swallowed status, as in claude.nix:
  # the merger is a store path built from this module, and ordering after
  # installPackages keeps a refusal from stranding linkGeneration.
  home.activation.antigravityAcpSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label 'Antigravity ACP' \
        --settings ${config.home.homeDirectory}/.gemini/antigravity-acp/settings.json \
        --declared ${acpDeclared}
    fi
  '';

  home.activation.antigravitySettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label 'Antigravity CLI' \
        --settings ${config.home.homeDirectory}/.gemini/antigravity-cli/settings.json \
        --declared ${cliDeclared}
    fi
  '';

  home.activation.antigravityMcpConfig = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label 'Antigravity CLI MCP' \
        --settings ${config.home.homeDirectory}/.gemini/config/mcp_config.json \
        --declared ${mcpDeclared} \
        --ledger ${config.home.homeDirectory}/.gemini/config/mcp-config-ownership.json
    fi
  '';
}
