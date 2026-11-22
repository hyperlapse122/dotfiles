{ pkgs }:

let
  python = pkgs.python3.withPackages (ps: [ ps.packaging ]);
in
pkgs.writeShellApplication {
  name = "agent-check";
  runtimeInputs = with pkgs; [
    coreutils
    gawk
    git
    go
    gnumake
    just
    markdownlint-cli2
    (import ./mise.nix { inherit pkgs; })
    nixfmt
  ];
  text = ''
    inspection=(${python}/bin/python3 -I ${../scripts/agent-check-inspect.py})
    inspection_path="$PATH:${pkgs.lib.makeBinPath [ pkgs.curl ]}"
  ''
  + builtins.readFile ../scripts/agent-check;
  derivationArgs.postCheck = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PATH="${
      pkgs.lib.makeBinPath [
        pkgs.git
        pkgs.bash
      ]
    }:$PATH"
    ${pkgs.python3}/bin/python3 ${../tests/agent-check.py} "$target"
  '';
}
