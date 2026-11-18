{ config, pkgs }:

{
  command = "${import ../dev/decide-package.nix { inherit config pkgs; }}/bin/decide-mcp";
  timeout = 1800;
}
