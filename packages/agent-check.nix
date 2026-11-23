{ pkgs }:

let
  python = pkgs.python3.withPackages (ps: [ ps.packaging ]);
in
{
  nativeBuildInputs = with pkgs; [
    bash
    coreutils
    curl
    git
    go
    markdownlint-cli2
    nixfmt
    python
  ];
  AGENT_CHECK_PYTHON = "${python}/bin/python3";
}
