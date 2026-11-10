{ pkgs, ... }:
{
  # GCC provides cc and c++, which rustc also uses as its linker. Only the
  # clang-tools (clangd, clang-format, clang-tidy) come from LLVM, because the
  # clang wrapper would collide with GCC's cc.
  home.packages = with pkgs; [
    clang-tools
    cmake
    gcc
    gdb
    gnumake
    ninja
    pkg-config
  ];
}
