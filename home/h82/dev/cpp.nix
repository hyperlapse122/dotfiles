{ lib, pkgs, ... }:
{
  # GCC provides cc and c++, which rustc also uses as its linker. Only the
  # clang-tools (clangd, clang-format, clang-tidy) come from LLVM, because the
  # clang wrapper would collide with GCC's cc. Take priority over Swift 6.4's
  # bundled lib/libclang.so when a profile links /lib; both toolchains resolve
  # ../lib relative to their own store paths.
  home.packages = with pkgs; [
    (lib.hiPrio clang-tools)
    cmake
    gcc
    gdb
    gnumake
    vcpkg
    ninja
    pkg-config
  ];
}
