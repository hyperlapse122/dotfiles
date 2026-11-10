/*
  Check interface:

    import ./tests/elf-load-segments.nix { inherit pkgs self fixtures; }

  Scans every ELF file in the closures of every configuration
  `tests/lib/configurations.nix` yields, production and bootstrap alike, and
  of the non-NixOS fixture hosts' Home Manager and system-manager outputs of
  the builder's architecture. It fails when any file has overlapping PT_LOAD
  segments, the mark patchelf 0.17 and later leave on a prebuilt executable
  they break (packages/patchelf-0-16.nix). Such a binary builds and installs,
  then segfaults on start, so only its program headers show the break.

  tests/check_elf_load_segments.py does the scan and names every broken file
  before it exits, and fails when it finds no ELF file at all.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  roots =
    map (entry: entry.config.system.build.toplevel) configurations.entries
    ++ lib.concatMap (entry: [
      entry.host.home.activationPackage
      entry.host.systemManager
    ]) configurations.linuxFixtures;

  closure = pkgs.closureInfo { rootPaths = roots; };
in
pkgs.runCommand "elf-load-segments-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    # The roots themselves, so their closures are readable in the sandbox;
    # closureInfo's output lists them but does not reference them.
    inherit roots;
  }
  ''
    ${configurations.guard}
    python3 -I ${./check_elf_load_segments.py} ${closure}/store-paths
    touch $out
  ''
