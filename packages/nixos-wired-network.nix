# nmcli stays on the caller's PATH: the systemd unit supplies it, and a test
# stub would otherwise be shadowed by a packaged copy.
{ pkgs }:
import ./wired-network-tool.nix {
  inherit pkgs;
  name = "nixos-wired-network";
}
