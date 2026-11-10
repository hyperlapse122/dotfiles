/*
  Check interface:

    import ./tests/vm-checks-guard.nix { inherit pkgs checks vmChecks; }

  `checks` is the flake's check set without this guard, and `vmChecks` is
  the set from tests/vm-checks.nix without its `all` aggregate.

  Fails when a `checks` entry is a NixOS VM test, so a new VM test cannot
  slip back into `nix flake check`. A VM test is any derivation whose system
  features include `nixos-test`: the feature that makes it need KVM. The
  testers wrap the result in `lib.lazyDerivation`, which hides
  `requiredSystemFeatures`, so the features are read from
  `config.rawTestDerivation` first.

  The detector is also run over every `vmChecks` entry, and the guard fails
  when one is not recognized or the set is empty. Without that, a detector
  reading the wrong attribute would match nothing and pass forever.

  Only names reach the builder, never a VM derivation, so building the guard
  never builds a VM test. Every problem is listed before it fails.
*/
{
  pkgs,
  checks,
  vmChecks,
}:
let
  inherit (pkgs) lib;

  systemFeatures =
    drv: drv.config.rawTestDerivation.requiredSystemFeatures or (drv.requiredSystemFeatures or [ ]);
  isVmTest = drv: builtins.elem "nixos-test" (systemFeatures drv);

  vmNames = lib.attrNames vmChecks;
  registered = lib.attrNames (lib.filterAttrs (_: isVmTest) checks);
  undetected = lib.filter (name: !isVmTest vmChecks.${name}) vmNames;
in
pkgs.runCommand "vm-checks-guard-tests" { } ''
  fail=0

  if [ ${toString (lib.length vmNames)} -eq 0 ]; then
    echo "vm-checks-guard: tests/vm-checks.nix declares no VM test, so the detector proves nothing" >&2
    fail=1
  fi

  for name in ${lib.escapeShellArgs undetected}; do
    echo "vm-checks-guard: vmChecks.$name carries no nixos-test system feature, so the detector would not recognize it" >&2
    fail=1
  done

  for name in ${lib.escapeShellArgs registered}; do
    echo "vm-checks-guard: checks.$name is a NixOS VM test; register it in tests/vm-checks.nix instead" >&2
    fail=1
  done

  [ "$fail" = 0 ] || exit 1
  touch $out
''
