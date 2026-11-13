{
  pkgs,
  self,
  entries ? null,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  userEntries = if entries == null then configurations.userEntries else entries;
  manifest = pkgs.writeText "flutter-profiles.json" (
    builtins.toJSON (
      map (
        entry:
        let
          user = entry.user;
          flutter = lib.findFirst (p: (p.meta.mainProgram or "") == "flutter") null (
            user.home.packages or [ ]
          );
          androidPath =
            if pkgs.stdenv.hostPlatform.isDarwin then
              "Library/Android/sdk"
            else
              lib.removePrefix "${user.home.homeDirectory or ""}/" "${user.xdg.dataHome or ""}/android-sdk";
        in
        {
          inherit (entry) name bootstrap;
          profile = if user ? home.path then toString user.home.path else null;
          sdk = if flutter != null && flutter ? sdk then toString flutter.sdk else null;
          android = if user ? home-files then "${user.home-files}/${androidPath}" else null;
        }
      ) userEntries
    )
  );
in
pkgs.runCommand "flutter-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./flutter-check.py} ${manifest}
  touch $out
''
