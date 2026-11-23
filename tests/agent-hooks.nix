{ pkgs }:
let
  inherit (pkgs) lib;
  renderer = import ./lib/quality-hook-renderer.nix { inherit pkgs; };
  declaration =
    harness: enable:
    pkgs.writeText "${harness}-quality-settings.json" (
      builtins.toJSON {
        inherit (renderer harness enable) hookGroups;
      }
    );
  extension = harness: source: (renderer harness true).renderExtension source;
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
    python3 ${./agent-hook-lifecycle.py} pi ${pi}/libexec/pi/pi ${extension "pi" ../home/h82/agents/pi-quality.ts}
    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      python3 ${./agent-hook-lifecycle.py} opencode ${opencode}/bin/opencode ${extension "opencode" ../home/h82/agents/opencode-quality.ts}
    ''}
    touch "$out"
  ''
