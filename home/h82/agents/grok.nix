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

  # Grok Build keeps user-scope MCP servers in ~/.grok/config.toml, the file
  # `grok mcp add -s user` writes beside its marketplace sources, so a store
  # symlink cannot live there. ownEntries upserts only the declared server.
  fff = import ./fff-server.nix { inherit pkgs; };
  declared = pkgs.writeText "grok-declared-settings.json" (
    builtins.toJSON {
      ownEntries = [
        {
          path = [ "mcp_servers" ];
          entries.fff = {
            inherit (fff) command args;
            enabled = true;
          };
        }
      ];
    }
  );
in
{
  # Grok Build writes its sign-in token, logs, and the rest of its config under
  # ~/.grok itself. Compound Engineering has no Grok review route, so it adds
  # no peer token.
  home.packages = [ (import ../../../packages/grok-build.nix { inherit pkgs; }) ];

  # Ordered after installPackages and not swallowing the merger's status, as
  # in claude.nix, so a refusal fails the rebuild without stranding
  # linkGeneration.
  home.activation.grokSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --format toml \
        --label 'Grok Build' \
        --settings ${config.home.homeDirectory}/.grok/config.toml \
        --declared ${declared} \
        --ledger ${config.home.homeDirectory}/.grok/config-ownership.json
    fi
  '';
}
