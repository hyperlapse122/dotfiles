{ pkgs }:

pkgs.writeScriptBin "publish-cli-auth" ''
  #!${pkgs.python3}/bin/python3
  ${builtins.readFile ../scripts/publish-cli-auth}
''
