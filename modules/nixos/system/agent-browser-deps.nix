{ pkgs, ... }:
{
  # NixOS equivalent of `agent-browser install --with-deps`, whose apt/dnf
  # lists live in agent-browser's cli/src/install.rs. The downloaded Chrome for
  # Testing is an FHS binary, so its libraries must be on the nix-ld path;
  # Home Manager packages never reach it. Only direct NEEDED sonames, plus the
  # dlopened GTK 3 and Xcursor libraries that upstream's apt list also names,
  # are listed: Nix-built libraries resolve their own dependencies through
  # RUNPATH. Optional dlopens such as libpci, libpulse, and libva are left out.
  programs.nix-ld.libraries = with pkgs; [
    glib
    nss
    nspr
    at-spi2-core
    dbus
    cups.lib
    expat
    libxcb
    libxkbcommon
    alsa-lib
    libgbm
    libx11
    libxext
    libxcomposite
    libxdamage
    libxfixes
    libxrandr
    cairo
    pango
    gtk3
    libxcursor
  ];

  # certutil, which agent-browser runs to import a CA certificate.
  environment.systemPackages = [ pkgs.nssTools ];

  fonts.packages = with pkgs; [
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf
    freefont_ttf
  ];
}
