# Checks every NixOS host's hosts/<host>/disko.nix against the invariants that
# modules/nixos/system/boot.nix and the boot-layout VM test rely on:
# - disk `main` carries a `luks` partition, whose partlabel `disk-main-luks`
#   boot.nix unlocks, holding a LUKS2 container named `cryptroot`.
# - a vfat ESP is mounted at `/boot`.
# - the btrfs filesystem inside the container has the subvolumes root, home,
#   nix, log, and swap at `/`, `/home`, `/nix`, `/var/log`, and `/swap`, and
#   the swap subvolume carries a swapfile.
#
# Returns the discovered host names, each host's imported disko layout (null
# when the file is missing), and one message per broken invariant on any
# host. The boot-layout-invariants check reports `problems`; the VM test
# takes its disk from `diskOf`.
{ lib }:
let
  # Only NixOS hosts have a disk layout; a non-NixOS host's distribution owns
  # its disks.
  hostNames = (import ../../lib/hosts.nix { inherit lib; } ../../hosts).nixos;

  diskOf =
    hostName:
    let
      path = ../../hosts + "/${hostName}/disko.nix";
    in
    if builtins.pathExists path then import path else null;

  expectedSubvolumes = {
    "/root" = "/";
    "/home" = "/home";
    "/nix" = "/nix";
    "/log" = "/var/log";
    "/swap" = "/swap";
  };

  layoutProblems =
    hostName:
    let
      disk = diskOf hostName;
      partitions = lib.attrByPath [ "disko" "devices" "disk" "main" "content" "partitions" ] { } disk;
      esps = lib.filter (
        partition:
        (partition.content.type or null) == "filesystem"
        && (partition.content.format or null) == "vfat"
        && (partition.content.mountpoint or null) == "/boot"
      ) (lib.attrValues partitions);
      luks = partitions.luks.content or { };
      formatArgs = luks.extraFormatArgs or [ ];
      isLuks2 = lib.any (
        i: lib.elemAt formatArgs i == "--type" && lib.elemAt formatArgs (i + 1) == "luks2"
      ) (lib.range 0 (lib.length formatArgs - 2));
      btrfs = luks.content or { };
      subvolumes = btrfs.subvolumes or { };
      label = "hosts/${hostName}/disko.nix";
    in
    if disk == null then
      [ "hosts/${hostName} has no disko.nix" ]
    else
      lib.optional (partitions == { }) "${label}: disk `main` declares no partitions"
      ++ lib.optional (esps == [ ]) "${label}: no vfat ESP is mounted at /boot"
      ++
        lib.optional ((luks.type or null) != "luks")
          "${label}: partition `luks` on disk `main` is not a LUKS container, so boot.nix's disk-main-luks partlabel unlocks nothing"
      ++ lib.optional (
        (luks.name or null) != "cryptroot"
      ) "${label}: the LUKS container is not named cryptroot"
      ++ lib.optional (!isLuks2) "${label}: the LUKS container is not formatted as LUKS2"
      ++ lib.optional ((btrfs.type or null) != "btrfs") "${label}: the LUKS container does not hold btrfs"
      ++ lib.concatLists (
        lib.mapAttrsToList (
          subvolume: mountpoint:
          lib.optional (
            (subvolumes.${subvolume}.mountpoint or null) != mountpoint
          ) "${label}: btrfs subvolume ${subvolume} is not mounted at ${mountpoint}"
        ) expectedSubvolumes
      )
      ++ lib.optional (
        (subvolumes."/swap".swap.swapfile or null) == null
      ) "${label}: the /swap subvolume carries no swapfile";
in
{
  inherit hostNames diskOf;
  problems = lib.concatMap layoutProblems hostNames;
}
