{ pkgs, ... }:
{
  # The shared instructions tell agents to load a TanStack package's skills
  # with `intent list` and `intent load` in a project that depends on one.
  home.packages = [ (import ../../../packages/tanstack-intent.nix { inherit pkgs; }) ];
}
