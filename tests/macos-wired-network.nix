/*
  Check interface:

    import ./tests/macos-wired-network.nix { inherit pkgs; }

  Runs tests/test_macos_wired_network.py against the packaged
  scripts/macos-wired-network.py, with the fake files from
  tests/lib/fake-secrets.nix and a networksetup stub on PATH:

  - a service already in the declared state gets no write and no output;
  - each differing group (IPv4, DNS, IPv6) is rewritten alone, with one line
    naming the group and the service;
  - no hardware port with the declared MAC, or no service for its device,
    skips silently;
  - only the adapter's service is queried or changed;
  - a missing, loose, or foreign-owned identity, a file for another identity,
    or a file missing a key warns, exits 0, and calls no networksetup;
  - a failed write warns for its group while the other groups reconcile;
  - no run prints a declared address or the MAC, even when networksetup
    echoes its arguments in an error.
*/
{ pkgs }:
let
  secrets = import ./lib/fake-secrets.nix { inherit pkgs; };
  tool = import ../packages/macos-wired-network.nix { inherit pkgs; };
in
pkgs.runCommand "macos-wired-network-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./test_macos_wired_network.py} ${pkgs.lib.getExe tool} ${secrets}
  touch "$out"
''
