{ pkgs }:

with pkgs;
[
  bash
  coreutils
  curl
  git
  go
  markdownlint-cli2
  nixfmt
  (python3.withPackages (ps: [ ps.packaging ]))
]
