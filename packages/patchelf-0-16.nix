{ pkgs }:

# patchelf 0.17 and later, which nixpkgs ships as 0.19.2, rewrite the program
# headers of some prebuilt executables into overlapping LOAD segments, and the
# patched binaries segfault on start (NixOS/patchelf#674). 0.16.1 is the last
# release that leaves them runnable. A package that hits it lists this
# patchelf in nativeBuildInputs, which puts it ahead of stdenv's on PATH. The
# elf-load-segments check finds any other binary in a host closure that hits
# it.
pkgs.patchelf.overrideAttrs {
  version = "0.16.1";
  src = pkgs.fetchurl {
    url = "https://github.com/NixOS/patchelf/releases/download/0.16.1/patchelf-0.16.1.tar.bz2";
    hash = "sha256-q5FfP0zMRj2Wzh5yaFsWMRD5RcIq7lvGIRjVet/wq30=";
  };
}
