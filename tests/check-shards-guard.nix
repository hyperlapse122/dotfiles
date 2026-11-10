/*
  Check interface:

    import ./tests/check-shards-guard.nix { inherit pkgs checkNames members; }

  `checkNames` is the attribute names of the flake's checks, this guard
  included, and `members` is the shard membership from
  tests/check-shards.nix.

  Fails when a check is in no shard, so CI would never build it; when a
  check is in more than one shard; when a shard names something that is not
  a check; or when a shard is empty, or there is no shard at all. CI builds
  the checks only through the shards, so a gap here is a check that silently
  stops running.

  Only names reach the builder, never a check derivation, so building the
  guard builds no other check. Every problem is listed before it fails.
*/
{
  pkgs,
  checkNames,
  members,
}:
let
  inherit (pkgs) lib;

  shardsOf =
    name:
    lib.concatLists (
      lib.mapAttrsToList (shard: names: map (_: shard) (lib.filter (entry: entry == name) names)) members
    );
  assigned = lib.unique (lib.concatLists (lib.attrValues members));

  missing = lib.filter (name: shardsOf name == [ ]) checkNames;
  duplicated = lib.filter (name: lib.length (shardsOf name) > 1) checkNames;
  unknown = lib.filter (name: !lib.elem name checkNames) assigned;
  empty = lib.attrNames (lib.filterAttrs (_: names: names == [ ]) members);
in
pkgs.runCommand "check-shards-guard-tests" { } ''
  fail=0

  if [ ${toString (lib.length (lib.attrNames members))} -eq 0 ]; then
    echo "check-shards-guard: no shard is defined, so CI builds no check" >&2
    fail=1
  fi

  for name in ${lib.escapeShellArgs missing}; do
    echo "check-shards-guard: checks.$name is in no shard, so CI never builds it" >&2
    fail=1
  done

  ${lib.concatMapStrings (name: ''
    echo ${lib.escapeShellArg "check-shards-guard: checks.${name} is in more than one shard: ${lib.concatStringsSep ", " (shardsOf name)}"} >&2
    fail=1
  '') duplicated}

  for name in ${lib.escapeShellArgs unknown}; do
    echo "check-shards-guard: a shard lists $name, which is not a check" >&2
    fail=1
  done

  for shard in ${lib.escapeShellArgs empty}; do
    echo "check-shards-guard: shard $shard is empty" >&2
    fail=1
  done

  [ "$fail" = 0 ] || exit 1
  touch $out
''
