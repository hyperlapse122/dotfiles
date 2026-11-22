{ pkgs, ... }:
{
  home.packages = [ (import ../../../packages/ant.nix { inherit pkgs; }) ];
  imports = [
    ./agent-plugins.nix
    ./claude.nix
    ./codex.nix
    ./cross-model-peers.nix
    ./fff.nix
    ./opencode.nix
    ./pi.nix
    ./instructions
    ./korean-skills.nix
    ./pinned-skills.nix
    ./skills.nix
    ./tanstack-intent.nix
    ./test-audit.nix
    ./tokscale.nix
    ./usage.nix
    ./ux-flows.nix
    ./xcode-skills.nix
  ];
}
