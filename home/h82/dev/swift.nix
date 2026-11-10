{ lib, pkgs, ... }:
{
  # nixpkgs marks swiftc broken on aarch64-linux until Swift 6.4.0, which
  # links with LLD instead of gold. The toolchain comes back on its own once
  # nixpkgs clears the flag.
  home.packages = lib.optionals (!pkgs.swiftPackages.swiftc.meta.broken) (
    with pkgs;
    [
      sourcekit-lsp
      swift
      swift-format
      swiftpm
    ]
  );
}
