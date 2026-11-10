{ pkgs }:
pkgs.writeShellApplication {
  name = "mobile-devices";
  # gawk for avdmanager's start script, which reads the JDK version with awk.
  runtimeInputs = [
    pkgs.gawk
    pkgs.gnugrep
    pkgs.jq
  ];
  text = builtins.readFile ../scripts/mobile-devices;
}
