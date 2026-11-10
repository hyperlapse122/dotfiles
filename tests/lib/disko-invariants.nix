# Checks every NixOS host's hosts/<host>/disko.nix against the invariants that
# modules/nixos/system/boot.nix and the boot-layout VM test rely on:
# - a vfat ESP is mounted at `/boot`.
# - disk `main` carries a `root` partition holding btrfs directly, with the
#   subvolumes root, home, nix, log, and swap at `/`, `/home`, `/nix`,
#   `/var/log`, and `/swap`, and the swap subvolume carries a swapfile.
# - no partition holds a LUKS container: boot.nix unlocks nothing, so an
#   encrypted root would never mount.
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
      btrfs = partitions.root.content or { };
      subvolumes = btrfs.subvolumes or { };
      label = "hosts/${hostName}/disko.nix";
    in
    if disk == null then
      [ "hosts/${hostName} has no disko.nix" ]
    else
      lib.optional (partitions == { }) "${label}: disk `main` declares no partitions"
      ++ lib.optional (esps == [ ]) "${label}: no vfat ESP is mounted at /boot"
      ++ lib.concatLists (
        lib.mapAttrsToList (
          name: partition:
          lib.optional (
            (partition.content.type or null) == "luks"
          ) "${label}: partition `${name}` holds a LUKS container, which boot.nix never unlocks"
        ) partitions
      )
      ++ lib.optional (
        (btrfs.type or null) != "btrfs"
      ) "${label}: partition `root` on disk `main` does not hold btrfs"
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
