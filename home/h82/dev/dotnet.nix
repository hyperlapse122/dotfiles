{ pkgs, ... }:
{
  # nixos-unstable does not gate on .NET VMR source builds, so sdk_8_0 and
  # sdk_10_0 fall back to multi-hour stage0/VMR bootstrap builds on macOS when
  # nixpkgs bumps .NET ahead of Hydra's Darwin builders.
  home.packages = [
    (pkgs.dotnetCorePackages.combinePackages [
      pkgs.dotnetCorePackages.sdk_8_0-bin
      pkgs.dotnetCorePackages.sdk_10_0-bin
    ])
  ];
}
