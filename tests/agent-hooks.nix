{ pkgs }:
let
  inherit (pkgs) lib;
  renderer =
    harness: enable: trustedProjects:
    import ../home/h82/agents/quality-hooks.nix {
      inherit pkgs lib harness;
      config.my.agentHooks = {
        inherit trustedProjects;
        stop = true;
        ${harness} = {
          inherit enable;
          postEdit = true;
          preShell = true;
          freezeTests = true;
        };
      };
    };
  declaration =
    harness: enable:
    pkgs.writeText "${harness}-quality-settings.json" (
      builtins.toJSON {
        inherit (renderer harness enable [ ]) hookGroups;
      }
    );
  extension = harness: source: (renderer harness true [ "/fixture-checkout" ]).renderExtension source;
  inherit (import ../packages/agent-tools.nix { inherit pkgs; }) agentSettings;
  pi = import ../packages/pi.nix { inherit pkgs; };
  opencode = import ../packages/opencode.nix { inherit pkgs; };
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
    python3 ${./agent-hook-lifecycle.py} \
      ${pi}/libexec/pi/pi ${extension "pi" ../home/h82/agents/pi-quality.ts} \
      ${opencode}/bin/opencode ${extension "opencode" ../home/h82/agents/opencode-quality.ts}
    touch "$out"
  ''
