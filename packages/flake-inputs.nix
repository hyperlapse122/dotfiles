{ pkgs }:

pkgs.writeScriptBin "flake-inputs" (
  "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../scripts/flake-inputs
)
