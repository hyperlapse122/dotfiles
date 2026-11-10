{ pkgs }:

pkgs.writeShellApplication {
  name = "network-recovery";
  # curl, route, arp, ifconfig, networksetup, dscacheutil, killall, launchctl,
  # scutil, nc, and sudo are macOS tools and are not runtimeInputs.
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
  ];
  text = builtins.readFile ../scripts/network-recovery;
}
