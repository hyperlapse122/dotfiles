{ pkgs, entries }:
let
  manifest = pkgs.writeText "zsh-prezto-profiles.json" (
    builtins.toJSON (
      map (entry: {
        inherit (entry) name;
        profile = entry.user.home.path or "";
        files = entry.user.home-files or "";
        home = entry.user.home.homeDirectory or "";
        sessionVars = "${entry.user.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
      }) entries
    )
  );
in
pkgs.runCommand "zsh-prezto-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./zsh-prezto.py} ${manifest}
    touch $out
  ''
