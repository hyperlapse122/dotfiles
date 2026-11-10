# The font packages every desktop host installs, NixOS and macOS alike, in the
# order NixOS has always listed them.
pkgs: with pkgs; [
  pretendard
  jetbrains-mono
  nerd-fonts.jetbrains-mono
  nerd-fonts.d2coding
  # The CBDT Twemoji build. The OpenType-SVG build draws in color only in
  # Firefox; Chromium, Qt, and GTK fall back to its monochrome glyphs.
  twitter-color-emoji
]
