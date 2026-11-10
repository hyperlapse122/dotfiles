{ pkgs, ... }:
{
  home.packages = [
    (pkgs.dotnetCorePackages.combinePackages [
      pkgs.dotnet-sdk_8
      pkgs.dotnet-sdk_10
    ])
  ];
}
