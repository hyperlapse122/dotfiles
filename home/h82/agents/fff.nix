{ pkgs, ... }:
{
  # On PATH for manual runs such as `fff-mcp --healthcheck`; every harness
  # starts the server by its store path (fff-server.nix).
  home.packages = [ pkgs.fff-mcp ];
}
