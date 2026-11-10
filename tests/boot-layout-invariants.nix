/*
  Check interface:

    import ./tests/boot-layout-invariants.nix { inherit pkgs; }

  Checks every NixOS host's hosts/<host>/disko.nix against the boot invariants in
  tests/lib/disko-invariants.nix, so a broken layout fails `nix flake check`
  without running the boot-layout VM test, which boots only the first host's
  layout. Every broken invariant on every host is listed from the builder
  before it fails, and it also fails when no host directory exists.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  invariants = import ./lib/disko-invariants.nix { inherit lib; };
in
pkgs.runCommand "boot-layout-invariants-tests" { } ''
  fail=0

  if [ ${toString (lib.length invariants.hostNames)} -eq 0 ]; then
    echo "boot-layout-invariants: no host directory under hosts/" >&2
    fail=1
  fi

  for problem in ${
    lib.escapeShellArgs (
      invariants.problems
      ++ lib.concatMap (
        entry:
        lib.optional (
          entry.config.boot.initrd.luks.devices.cryptroot.device
          != entry.config.disko.devices.disk.main.content.partitions.luks.device
        ) "${entry.name}: evaluated cryptroot device differs from disko's luks partition"
      ) (import ./lib/configurations.nix { inherit pkgs self; }).entries
    )
  }; do
    echo "boot-layout-invariants: $problem" >&2
    fail=1
  done

  [ "$fail" = 0 ] || exit 1
  touch $out
''
