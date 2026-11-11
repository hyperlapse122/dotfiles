{ pkgs }:
pkgs.writeShellApplication {
  name = "macos-wired-network";
  # networksetup comes from macOS's own /usr/sbin at activation.
  runtimeInputs = [
    pkgs.python3
    pkgs.sops
  ];
  text = ''exec python3 ${../scripts/macos-wired-network.py} "$@"'';
}
