/*
  Check interface:

    import ./tests/nixos-wired-network.nix { inherit pkgs; }

  Runs tests/test_nixos_wired_network.py against the packaged
  scripts/nixos-wired-network.py, with the fake files from
  tests/lib/fake-secrets.nix and an nmcli stub on PATH:

  - a valid declaration renders one 0600 NetworkManager keyfile with the
    address, prefix, router, DNS servers, normalized MAC, IPv6 off, and no
    DNS-priority, route-metric, or default-route key, then reloads
    NetworkManager;
  - the output directories are created when absent and no temporary file is
    left behind;
  - a missing key, an invalid value, an IPv6 DNS server, a prefix outside 1
    to 30, a router outside the address's network, or a malformed MAC writes
    nothing, calls no nmcli, exits 0, and prints one warning naming the field;
  - a file for another identity, or a loose or foreign-owned identity, does the
    same;
  - a rejected file leaves an earlier keyfile byte-identical, and a valid one
    replaces it;
  - a failing nmcli leaves the keyfile in place;
  - no run prints a declared address or the MAC.
*/
{ pkgs }:
let
  secrets = import ./lib/fake-secrets.nix { inherit pkgs; };
  tool = import ../packages/nixos-wired-network.nix { inherit pkgs; };
in
pkgs.runCommand "nixos-wired-network-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./test_nixos_wired_network.py} ${pkgs.lib.getExe tool} ${secrets}
  touch "$out"
''
