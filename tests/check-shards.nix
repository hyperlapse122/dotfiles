/*
  Shard set interface:

    import ./tests/check-shards.nix { inherit pkgs checks hostClosureChecks lightCount; }

  Splits the flake's checks into the shards CI builds, one job per shard,
  in the `check-shards` matrix of .github/workflows/check.yml. flake.nix
  exposes the result as `legacyPackages.<system>.checkShards`, so
  `nix build .#checkShards.<name>` builds one shard locally.

  - `hosts` holds `hostClosureChecks`: the checks whose closure carries a
    full NixOS system path or a Home Manager or system-manager generation.
    Each of them reads every host, so splitting them would make every shard
    that holds one fetch all the host closures again.
  - `light-1` through `light-<lightCount>` split the other checks by
    position in the sorted name list, modulo `lightCount`.

  Returns `{ members, shards }`. `members` maps each shard name to its check
  names and is plain data, so `check-shards-guard` reads it without forcing a
  check. `shards` maps each shard name to a linkFarm of its checks; building
  one builds every check it links.
*/
{
  pkgs,
  checks,
  hostClosureChecks,
  lightCount,
}:
let
  inherit (pkgs) lib;

  lightNames = lib.subtractLists hostClosureChecks (lib.attrNames checks);

  lightShard =
    index:
    lib.pipe lightNames [
      (lib.imap0 (position: name: { inherit position name; }))
      (lib.filter (entry: lib.mod entry.position lightCount == index))
      (map (entry: entry.name))
    ];

  members = {
    hosts = hostClosureChecks;
  }
  // lib.listToAttrs (
    lib.genList (index: lib.nameValuePair "light-${toString (index + 1)}" (lightShard index)) lightCount
  );
in
{
  inherit members;
  shards = lib.mapAttrs (
    shard: names: pkgs.linkFarm "check-shard-${shard}" (lib.genAttrs names (name: checks.${name}))
  ) members;
}
