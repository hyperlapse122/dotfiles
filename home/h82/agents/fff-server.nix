# The fff MCP server every harness registers: one command and argument list,
# rendered into each harness's own entry shape. The store path rather than a
# PATH lookup, because GUI and T3 Code sessions do not inherit the login
# shell's PATH. --no-update-check, because only a nixpkgs bump can update it.
{ pkgs }:
{
  command = "${pkgs.fff-mcp}/bin/fff-mcp";
  args = [ "--no-update-check" ];
}
