{ pkgs, entries }:
let
  manifest = pkgs.writeText "zsh-prezto-profiles.json" (
    builtins.toJSON (
      map (entry: {
        inherit (entry) name kind bootstrap;
        bash = "${pkgs.bashInteractive}/bin/bash";
        locale = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
        profile = entry.user.home.path or "";
        files = entry.user.home-files or "";
        home = entry.user.home.homeDirectory or "";
        sessionVars = "${entry.user.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
        collisionCheck = pkgs.writeShellScript "shell-file-collisions" (
          entry.user.home.activation.checkLinkTargets.data or ""
        );
      }) entries
    )
  );
in
pkgs.runCommand "zsh-prezto-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
    ];
  }
  ''
    python3 ${./zsh-prezto.py} ${manifest}
    touch $out
  ''
