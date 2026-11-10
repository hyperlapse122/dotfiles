{ pkgs }:

pkgs.writeShellApplication {
  name = "tls-inspection-ca";
  # security and launchctl come from macOS's own PATH at activation.
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.openssl
    pkgs.python3
    pkgs.sops
  ];
  text = builtins.readFile ../scripts/tls-inspection-ca;
}
