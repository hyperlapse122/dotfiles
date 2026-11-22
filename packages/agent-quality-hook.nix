{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pygit2 ]);
in
pkgs.writeScriptBin "agent-quality-hook" (
  "#!${python}/bin/python3 -I\n"
  +
    builtins.replaceStrings
      [ "@inspector@" "@caBundle@" ]
      [
        "${../scripts/agent-check-inspect.py}"
        "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ]
      (pkgs.lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile ../scripts/agent-quality-hook))
)
