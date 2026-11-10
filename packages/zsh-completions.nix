{ pkgs }:
pkgs.runCommand "personal-zsh-completions" { nativeBuildInputs = [ pkgs.zsh ]; } ''
    export HOME=$TMPDIR/home
  mkdir -p "$HOME" $out/share/zsh/site-functions
    ${
      import ./codex.nix { inherit pkgs; }
    }/bin/codex completion zsh > $out/share/zsh/site-functions/_codex
    ${pkgs.gh}/bin/gh completion -s zsh > $out/share/zsh/site-functions/_gh
    ${pkgs.glab}/bin/glab completion -s zsh > $out/share/zsh/site-functions/_glab
    cp ${pkgs.ghq}/share/zsh/site-functions/_ghq $out/share/zsh/site-functions/_ghq
    ${
      import ./mise.nix { inherit pkgs; }
    }/bin/mise completion zsh > $out/share/zsh/site-functions/_mise
    ${pkgs.usage}/bin/usage --completions zsh > $out/share/zsh/site-functions/_usage
  for file in $out/share/zsh/site-functions/*; do
    zsh -n "$file"
  done
  zsh -fc '
    fpath=("$1" $fpath)
    autoload -Uz compinit
    compinit -D
    for completionCommand in codex gh glab ghq mise usage; do
      [[ ''${_comps[$completionCommand]-} == _$completionCommand ]] || exit 1
    done
  ' zsh "$out/share/zsh/site-functions"
''
