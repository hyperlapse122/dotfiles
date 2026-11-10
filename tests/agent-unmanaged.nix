# Check materialized profiles and Home Manager deliveries on each native platform.
{ pkgs, entries }:
let
  manifest = pkgs.writeText "agent-unmanaged.json" (
    builtins.toJSON (
      map (entry: {
        inherit (entry) name;
        modules =
          map toString (pkgs.lib.filesystem.listFilesRecursive ../home/h82/agents)
          ++ map toString (pkgs.lib.filesystem.listFilesRecursive ../modules);
        packages = map (package: package.pname or (pkgs.lib.getName package)) entry.user.home.packages;
        files = toString entry.user.home-files;
        profile = toString entry.user.home.path;
      }) entries
    )
  );
in
pkgs.runCommand "agent-unmanaged" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./agent-unmanaged.py} ${manifest}
  touch $out
''
