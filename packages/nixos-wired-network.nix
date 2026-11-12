{ pkgs }:
let
  # Python puts the script's real directory on sys.path, so the shared module
  # has to be copied next to the tool rather than symlinked.
  scripts = pkgs.runCommand "nixos-wired-network-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts/nixos-wired-network.py} "$out/nixos-wired-network.py"
    cp ${../scripts/wired_network_common.py} "$out/wired_network_common.py"
  '';
in
pkgs.writeShellApplication {
  name = "nixos-wired-network";
  # nmcli comes from the calling unit's path, so a stub can stand in for it.
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
  ];
  text = ''exec python3 ${scripts}/nixos-wired-network.py "$@"'';
}
