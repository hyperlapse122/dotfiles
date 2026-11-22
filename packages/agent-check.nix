{ pkgs }:

pkgs.writeShellApplication {
  name = "agent-check";
  runtimeInputs = with pkgs; [
    coreutils
    gawk
    git
    gnumake
    just
    markdownlint-cli2
    (import ./mise.nix { inherit pkgs; })
    nixfmt
  ];
  text = builtins.readFile ../scripts/agent-check;
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
