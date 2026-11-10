{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./chatgpt-version.json);
in
pkgs.stdenv.mkDerivation {
  pname = "chatgpt";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/${source.filename}";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    pkgs.dpkg
    # Newer patchelf creates overlapping LOAD segments in cua_node/bin/node.
    (import ./patchelf-0-16.nix { inherit pkgs; })
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
    pkgs.file
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
    pkgs.gdk-pixbuf
    pkgs.glib
    pkgs.gtk3
    pkgs.libGL
    pkgs.libdrm
    pkgs.libnotify
    pkgs.libpulseaudio
    pkgs.libsecret
    pkgs.libusb1
    pkgs.libuuid
    pkgs.libxcb
    pkgs.libxkbcommon
    pkgs.libgbm
    pkgs.nspr
    pkgs.nss
    pkgs.openssl
    pkgs.pango
    pkgs.systemdLibs
    pkgs.tpm2-tss
    pkgs.vulkan-loader
    pkgs.libx11
    pkgs.libxcomposite
    pkgs.libxdamage
    pkgs.libxext
    pkgs.libxfixes
    pkgs.libxrandr
    pkgs.libxrender
    pkgs.libxtst
    pkgs.libxshmfence
  ];

  appendRunpaths = lib.makeLibraryPath [
    pkgs.libGL
    pkgs.libpulseaudio
  ];

  # Chromium loads the Qt shims only under a Qt platform theme; their Qt
  # libraries stay unresolved rather than pulling Qt into the closure.
  autoPatchelfIgnoreMissingDeps = [
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
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
    # Native module prebuilds ship for every platform; keep only glibc x86_64.
    find usr/lib/chatgpt -type d -path '*/prebuilds/*' -prune ! -name '*linux-x64' -exec rm -rf {} +
    find usr/lib/chatgpt -path '*/prebuilds/*' -name '*musl*' -exec rm -rf {} +

    # autoPatchelf skips only ET_EXEC static binaries. The bundled Codex, rg,
    # and code-mode host are static-pie (ET_DYN with no interpreter), so it
    # would add the runpath below and leave them segfaulting. Set every
    # static-pie file aside here and put it back after autoPatchelf in
    # postFixup; a static binary a later release adds is covered too.
    (cd usr/lib/chatgpt && find . -type f -print0 | while IFS= read -r -d "" file; do
      if file -b "$file" | grep -q 'static-pie linked'; then
        install -Dm755 "$file" "$TMPDIR/static-pie/$file"
      fi
    done)
    mv usr/lib/chatgpt $out/lib/

    # No ozone flags: upstream marks native Wayland experimental, so the app
    # keeps its X11 default. bubblewrap and ripgrep are what the bundled Codex
    # sandboxes and searches with, as in packages/codex.nix; the .deb ships
    # no bwrap of its own and NixOS has none on PATH.
    makeWrapper $out/lib/chatgpt/ChatGPT $out/bin/chatgpt \
      --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
      --prefix XDG_DATA_DIRS : "${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
      --suffix PATH : "${
        lib.makeBinPath [
          pkgs.xdg-utils
          pkgs.bubblewrap
          pkgs.ripgrep
        ]
      }"

    runHook postInstall
  '';

  # postFixup runs before the postFixupHooks array the hook registers itself
  # in, so restoring there would precede the patching. The hook is disabled
  # and run here instead, ahead of the restore.
  dontAutoPatchelf = true;
  postFixup = ''
    autoPatchelf -- "$out"
    (cd "$TMPDIR/static-pie" && find . -type f -print0 | while IFS= read -r -d "" file; do
      install -Dm755 "$file" "$out/lib/chatgpt/$file"
    done)
  '';

  meta = {
    description = "ChatGPT for Linux";
    homepage = "https://chatgpt.com";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "chatgpt";
  };
}
