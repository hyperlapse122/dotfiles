# The shared cache trust, read from materialized outputs: each darwin host's
# rendered /etc/nix/nix.conf must carry both substituters and the published
# nix-community key. cache.nixos.org stays because setting substituters
# replaces the built-in default.
{
  pkgs,
  configurations,
}:
let
  inherit (pkgs) lib;
  etcFile = import ./lib/etc-file.nix { inherit lib; };

  nixConf =
    name:
    let
      path = etcFile configurations.${name}.config "nix/nix.conf";
    in
    lib.throwIf (path == null) "nix-settings: ${name} does not materialize /etc/nix/nix.conf" path;
  nixConfs = map nixConf (lib.attrNames configurations);
in
pkgs.runCommand "nix-settings-cache-trust"
  {
    nixConfs = lib.concatStringsSep " " nixConfs;
  }
  ''
    for conf in $nixConfs; do
      for needle in \
        "https://cache.nixos.org" \
        "https://nix-community.cachix.org" \
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="; do
        grep -q -- "$needle" "$conf" || {
          echo "$conf is missing $needle" >&2
          exit 1
        }
      done
    done
    touch "$out"
  ''
