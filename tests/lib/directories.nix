# The names of the directories directly under `dir`. Host discovery in
# flake.nix and every check that pairs or scans host directories share this,
# so they all agree on what counts as a host.
{ lib }: dir: lib.attrNames (lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir dir))
