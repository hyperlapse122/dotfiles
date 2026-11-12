# networksetup comes from macOS's own /usr/sbin at activation.
{ pkgs }:
import ./wired-network-tool.nix {
  inherit pkgs;
  name = "macos-wired-network";
}
