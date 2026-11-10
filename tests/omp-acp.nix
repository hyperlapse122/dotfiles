{
  pkgs,
  self,
  fixtures ? [ ],
}:
let
  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  users =
    if pkgs.stdenv.hostPlatform.isDarwin then
      map (entry: entry.host.config.home-manager.users.${entry.host.config.my.user.name}) (
        import ./lib/darwin-fixtures.nix { inherit (self) inputs; }
      )
    else
      map (entry: entry.user) (
        pkgs.lib.filter (
          entry: entry.config.nixpkgs.hostPlatform.system == pkgs.stdenv.hostPlatform.system
        ) configurations.entries
      )
      ++ map (entry: entry.host.home.config) configurations.linuxFixtures;
  deliveries = pkgs.writeText "omp-acp-deliveries.json" (
    builtins.toJSON (
      pkgs.lib.unique (
        map (user: {
          home = user.home.homeDirectory;
          activation = user.home.activation.t3codeSettings.data or "";
          documents = pkgs.lib.mapAttrs (_: path: toString path) user.my.omp.documents;
        }) (pkgs.lib.filter (user: user.my.t3.cli.enable || user.my.t3.desktop.enable) users)
      )
    )
  );
in
pkgs.runCommand "omp-acp-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.bash
      pkgs.openssl
    ];
  }
  ''
    python3 -I ${./omp-acp.py} ${deliveries} \
      ${../home/h82/agents/synthetic-catalog.json} ${../home/h82/agents/openrouter-catalog.json}
    touch $out
  ''
