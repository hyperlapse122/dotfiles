{ ... }:
{
  imports = [
    ./agent-plugins.nix
    ./claude.nix
    ./codex.nix
    ./cross-model-peers.nix
    ./fff.nix
    ./gemini.nix
    ./grok.nix
    ./instructions
    ./korean-skills.nix
    ./omp.nix
    ./pinned-skills.nix
    ./retire-orca.nix
    ./skills.nix
    ./tanstack-intent.nix
    ./test-audit.nix
    ./tokscale.nix
    ./usage.nix
    ./ux-flows.nix
  ];
}
