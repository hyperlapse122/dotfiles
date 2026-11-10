{ pkgs }:
pkgs.writeShellApplication {
  name = "macos-xcode";
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
    pkgs.xcodes
  ];
  text = ''exec python3 ${../scripts/macos-xcode.py} "$@"'';
}
