{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./wifiman-desktop-version.json);
in
pkgs.stdenv.mkDerivation {
  pname = "wifiman-desktop";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://desktop.wifiman.com/wifiman-desktop-${source.version}-amd64.deb";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    pkgs.dpkg
    pkgs.autoPatchelfHook
    pkgs.wrapGAppsHook3
  ];

  buildInputs = [
    pkgs.cairo
    pkgs.dbus
    pkgs.gdk-pixbuf
    pkgs.glib
    pkgs.gtk3
    pkgs.libsoup_3
    pkgs.webkitgtk_4_1
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile $src | tar --extract
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r usr/share $out/share
    # The daemon's helpers (wg, wg-quick, wireguard-go, wg_report.sh) and .env
    # stay together; modules/nixos/services/wifiman.nix links them into the
    # daemon's state directory.
    mkdir -p $out/lib
    cp -r usr/lib/wifiman-desktop $out/lib/
    # The .deb ships it without an exec bit, and patchShebangs only rewrites
    # executable files, so its #!/bin/bash would survive.
    chmod 0755 $out/lib/wifiman-desktop/wg_report.sh
    install -Dm755 usr/bin/wifiman-desktop $out/bin/wifiman-desktop

    runHook postInstall
  '';

  # The GUI runs `iw phy | awk ...` itself to read the radio's frequencies.
  preFixup = ''
    gappsWrapperArgs+=(--prefix PATH : ${
      lib.makeBinPath [
        pkgs.iw
        pkgs.gawk
      ]
    })
  '';

  # The tray icon library is dlopened by name rather than linked, so
  # autoPatchelf never sees it, and it resets the runpath of anything it
  # patches. postFixup runs before the postFixupHooks array the hook registers
  # itself in, so the hook is disabled and run here, ahead of the runpath.
  # Only the GUI gets it: adding a runpath to the prebuilt Go binaries moves
  # their dynamic section and they segfault.
  dontAutoPatchelf = true;
  postFixup = ''
    autoPatchelf -- "$out"
    patchelf --add-rpath ${lib.makeLibraryPath [ pkgs.libayatana-appindicator ]} \
      $out/bin/.wifiman-desktop-wrapped
  '';

  meta = {
    description = "UniFi WiFiman Desktop for Linux";
    homepage = "https://ui.com/download/app/wifiman-desktop";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "wifiman-desktop";
  };
}
