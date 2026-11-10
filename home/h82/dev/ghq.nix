{ pkgs, ... }:
{
  home.packages = [ pkgs.ghq ];

  # ghq reads its root from Git config; clones land at <root>/<host>/<owner>/<repo>.
  programs.git.settings.ghq.root = "~/src";
}
