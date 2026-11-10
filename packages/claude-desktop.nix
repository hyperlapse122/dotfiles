{ pkgs }:

let
  source = builtins.fromJSON (builtins.readFile ./claude-desktop-version.json);
in
pkgs.stdenv.mkDerivation rec {
  pname = "claude-desktop";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
    hash = source.hash;
  };

  nativeBuildInputs = [
    pkgs.dpkg
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
    pkgs.asar
  ];

  buildInputs = [
    pkgs.alsa-lib
    pkgs.at-spi2-atk
    pkgs.at-spi2-core
    pkgs.atk
    pkgs.cairo
    pkgs.cups
    pkgs.dbus
    pkgs.expat
    pkgs.glib
    pkgs.gtk3
    pkgs.libGL
    pkgs.libdrm
    pkgs.libnotify
    pkgs.libpulseaudio
    pkgs.libsecret
    pkgs.libuuid
    pkgs.libxcb
    pkgs.libxkbcommon
    pkgs.libgbm
    pkgs.nspr
    pkgs.nss
    pkgs.pango
    pkgs.pipewire
    pkgs.systemdLibs
    pkgs.libx11
    pkgs.libxcomposite
    pkgs.libxdamage
    pkgs.libxext
    pkgs.libxfixes
    pkgs.libxrandr
    pkgs.libxrender
    pkgs.libxtst
    pkgs.libxshmfence
    pkgs.libseccomp
    pkgs.libcap_ng
  ];

  appendRunpaths = pkgs.lib.makeLibraryPath [
    pkgs.libGL
    pkgs.libpulseaudio
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile $src | tar --extract
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,share,lib}
    cp -r usr/share/* $out/share/
    cp -r usr/lib/claude-desktop $out/lib/

    # Patch Cowork firmware and virtiofsd paths in app.asar
    asar extract $out/lib/claude-desktop/resources/app.asar asar-unpacked
    for js in asar-unpacked/.vite/build/index.chunk-*.js; do
      if [ -f "$js" ] && grep -q '/usr/share/OVMF' "$js"; then
        substituteInPlace "$js" \
          --replace-fail '["/usr/share/OVMF/OVMF_CODE_4M.fd","/usr/share/OVMF/OVMF_CODE.fd"]' '["${pkgs.OVMFFull.fd}/FV/OVMF_CODE.fd"]' \
          --replace-fail '["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"]' '["${pkgs.virtiofsd}/bin/virtiofsd"]'
      fi
    done
    rm -rf asar-unpacked/compile-cache
    rm $out/lib/claude-desktop/resources/app.asar
    asar pack asar-unpacked $out/lib/claude-desktop/resources/app.asar
    rm -rf asar-unpacked

    # Replace the bin symlink with makeWrapper
    makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
      --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
      --suffix PATH : "${
        pkgs.lib.makeBinPath [
          pkgs.xdg-utils
          pkgs.qemu_kvm
          pkgs.virtiofsd
        ]
      }" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Claude Desktop for Linux";
    homepage = "https://claude.ai";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude-desktop";
  };
}
