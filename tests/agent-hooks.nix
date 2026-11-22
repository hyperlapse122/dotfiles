{ pkgs }:
let
  inherit (pkgs) lib;
  declaration =
    harness: enable:
    let
      renderer = import ../home/h82/agents/quality-hooks.nix {
        inherit pkgs lib harness;
        config.my.agentHooks = {
          trustedProjects = [ ];
          stop = true;
          ${harness} = {
            inherit enable;
            postEdit = true;
            preShell = true;
            freezeTests = true;
          };
        };
      };
    in
    pkgs.writeText "${harness}-quality-settings.json" (
      builtins.toJSON {
        inherit (renderer) hookGroups;
      }
    );
  inherit (import ../packages/agent-tools.nix { inherit pkgs; }) agentSettings;
in
pkgs.runCommand "agent-hooks-tests"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.python3
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${./agent-hooks.py} ${agentSettings}/bin/agent-settings \
      ${declaration "claude" true} ${declaration "claude" false} \
      ${declaration "codex" true} ${declaration "codex" false}
    touch "$out"
  ''
