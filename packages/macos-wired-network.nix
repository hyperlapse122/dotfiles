{ pkgs }:
let
  # Python puts the script's real directory on sys.path, so the shared module
  # has to be copied next to the tool rather than symlinked.
  scripts = pkgs.runCommand "macos-wired-network-scripts" { } ''
    mkdir -p "$out"
    cp ${../scripts/macos-wired-network.py} "$out/macos-wired-network.py"
    cp ${../scripts/wired_network_common.py} "$out/wired_network_common.py"
  '';
in
pkgs.writeShellApplication {
  name = "macos-wired-network";
  # networksetup comes from macOS's own /usr/sbin at activation.
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
  ];
  text = ''exec python3 ${scripts}/macos-wired-network.py "$@"'';
}
