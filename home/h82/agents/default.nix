{ pkgs, inputs, ... }:
{
  home.packages = [
    (import ../../../packages/ant.nix { inherit pkgs; })
    (import ../../../packages/agent-browser.nix { inherit pkgs; })
    (import ../../../packages/ctx7.nix { inherit pkgs; })
    (import ../../../packages/impeccable.nix { inherit pkgs inputs; })
  ];
  imports = [
    ./agent-check.nix
    ./agent-hooks.nix
    ./agent-plugins.nix
    ./claude.nix
    ./codex.nix
    ./cross-model-peers.nix
    ./fff.nix
    ./opencode.nix
    ./omp.nix
    ./official-skills.nix
    ./pi.nix
    ./instructions
    ./korean-skills.nix
    ./pinned-skills.nix
    ./skills.nix
    ./tanstack-intent.nix
    ./tokscale.nix
    ./xcode-skills.nix
  ];
}
