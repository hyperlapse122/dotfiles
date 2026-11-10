{ pkgs }:
{
  mode ? "settings",
  script,
  home,
  contract,
}:
let
  python = pkgs.python3.withPackages (p: [ p.tomlkit ]);
  block = pkgs.writeText "agent-activation-block.sh" script;
  expected = pkgs.writeText "agent-activation-contract.json" (builtins.toJSON contract);
in
''
  if ! ${python}/bin/python ${./agent-activation.py} ${
    pkgs.lib.escapeShellArgs [
      mode
      (toString block)
      home
      (toString expected)
      "${pkgs.bash}/bin/bash"
    ]
  }; then
    echo 'complete ${mode} activation failed its runtime contract' >&2
    failed=1
  fi
''
