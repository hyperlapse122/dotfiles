# Keep host closures together. Distribute the remaining checks across the light CI jobs.
{
  pkgs,
  checks,
  hostClosureChecks,
}:
let
  inherit (pkgs) lib;
  lightCount = 3;

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
