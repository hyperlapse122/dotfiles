{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.dbus-python ]);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "desktop-ssh-session-active";
  version = "1";
  src = ../scripts/desktop-ssh-session-active;
  dontUnpack = true;
  installPhase = ''
    install -Dm755 "$src" "$out/bin/desktop-ssh-session-active"
    substituteInPlace "$out/bin/desktop-ssh-session-active" \
      --replace-fail '#!/usr/bin/env python3' '#!${python}/bin/python3'
  '';
}
