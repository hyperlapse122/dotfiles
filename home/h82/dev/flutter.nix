{
  config,
  lib,
  pkgs,
  ...
}:
let
  isDarwin = config.my.kind == "darwin";
  flutter = import ../../../packages/flutter.nix {
    inherit pkgs;
    androidSdk = import ../../../packages/android-sdk.nix { inherit pkgs; };
    javaHome = config.programs.java.package.home;
    chromeExecutable =
      if isDarwin then
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      else
        lib.getExe pkgs.google-chrome;
  };
in
{
  home.packages = [ flutter ] ++ lib.optionals isDarwin [ pkgs.cocoapods ];
}
