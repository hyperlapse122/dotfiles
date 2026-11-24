{ pkgs, omp }:
let
  # The pinned Linux release needs nix-ld on the host, so the build sandbox
  # cannot execute it. Linux installs this generated copy; Darwin regenerates
  # it from the pinned package and fails if the checked-in copy drifts.
  ompCompletion = ./zsh-completions/_omp;
in
pkgs.runCommand "personal-zsh-completions"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.zsh
    ];
  }
  ''
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
      ${
        if pkgs.stdenv.hostPlatform.isDarwin then
          ''
            ${omp}/bin/omp completions zsh > $out/share/zsh/site-functions/_omp
            cmp ${ompCompletion} $out/share/zsh/site-functions/_omp
          ''
        else
          ''
            cp ${ompCompletion} $out/share/zsh/site-functions/_omp
          ''
      }
      ${pkgs.usage}/bin/usage --completions zsh > $out/share/zsh/site-functions/_usage
    for file in $out/share/zsh/site-functions/*; do
      zsh -n "$file"
    done
    zsh -fc '
      fpath=("$1" $fpath)
      autoload -Uz compinit
      compinit -D
      for completionCommand in codex gh glab ghq mise omp usage; do
        [[ ''${_comps[$completionCommand]-} == _$completionCommand ]] || exit 1
      done
    ' zsh "$out/share/zsh/site-functions"
  ''
