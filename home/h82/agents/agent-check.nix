{ pkgs, ... }:
{
  home.packages = with pkgs; [
    (import ../../../packages/agent-check.nix { inherit pkgs; })
    go
    markdownlint-cli2
    nixfmt
    pyright
    statix
    typescript
  ];
}
