# Font families shared by NixOS and macOS.
pkgs:
with pkgs;
[
  pretendard
  jetbrains-mono
  d2coding
  # The CBDT Twemoji build. The OpenType-SVG build draws in color only in
  # Firefox; Chromium, Qt, and GTK fall back to its monochrome glyphs.
  twitter-color-emoji
]
++ (import ../../packages/overlay-fonts.nix { inherit pkgs; })
