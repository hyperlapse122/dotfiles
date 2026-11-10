{ config, lib, ... }:
let
  # Compound Engineering matches each token against `,<list>,`, so the list is
  # joined with a bare comma; a space beside it would hide the next token.
  peers = lib.concatStringsSep "," (
    lib.unique (lib.sort lib.lessThan config.my.agents.crossModelPeers)
  );
  # CE clamps the count to 0..2, and 3.31.0 reads it only during discovery.
  maxPeers = "2";
  peerVariables = {
    CROSS_MODEL_PEERS = peers;
    CROSS_MODEL_MAX_PEERS = maxPeers;
  };
in
{
  options.my.agents.crossModelPeers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Compound Engineering review route tokens (claude, codex, antigravity)
      that CROSS_MODEL_PEERS allows. Each agent module adds the token of the
      harness it installs. Compound Engineering has no route for OMP, so
      OMP adds no peer token; explicit reviews follow its own tool guidance.
    '';
  };

  config = lib.mkMerge [
    {
      home.sessionVariables = peerVariables;
      systemd.user.sessionVariables = peerVariables;
    }
    # Finder and Dock launches never read hm-session-vars.sh, so GUI apps such
    # as T3 Code get the allowlist from launchd instead.
    (lib.mkIf (config.my.kind == "darwin") {
      launchd.agents.cross-model-peers = {
        enable = true;
        config = {
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''
              /bin/launchctl setenv CROSS_MODEL_PEERS ${lib.escapeShellArg peers}
              /bin/launchctl setenv CROSS_MODEL_MAX_PEERS ${maxPeers}
            ''
          ];
          RunAtLoad = true;
        };
      };
    })
  ];
}
