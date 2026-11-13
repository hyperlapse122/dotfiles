{ pkgs }:
pkgs.writeShellApplication {
  name = "xcode-skills";
  runtimeInputs = [ pkgs.coreutils ];
  text = builtins.readFile ../scripts/xcode-skills;
}
