{ pkgs }:
pkgs.writeScriptBin "agent-quality-hook" (
  "#!${pkgs.python3}/bin/python3 -I\n"
  +
    builtins.replaceStrings
      [ "@git@" "@agentCheck@" ]
      [
        "${pkgs.git}/bin/git"
        "${import ./agent-check.nix { inherit pkgs; }}/bin/agent-check"
      ]
      (pkgs.lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile ../scripts/agent-quality-hook))
)
