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
