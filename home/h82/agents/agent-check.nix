{ pkgs, ... }:
{
  home.packages = with pkgs; [
    go
    markdownlint-cli2
    nixfmt
    pyright
    statix
    typescript
  ];
}
