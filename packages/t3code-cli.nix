{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./t3code-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  pin =
    (source.platforms.${system}
      or (throw "packages/t3code-release.json pins no t3code-cli asset for ${system}")
    ).cli;
  # The tarball's single top-level directory, and the Node platform key
  # (`linux-x64`, `linux-arm64`, `darwin-arm64`) its native addons are built
  # for.
  topLevel = lib.removeSuffix ".tar.gz" pin.asset;
  platformKey = lib.removePrefix "t3-${source.version}-" topLevel;
in
pkgs.stdenv.mkDerivation {
  pname = "t3code-cli";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/${source.tag}/${pin.asset}";
    inherit (pin) hash;
  };

  sourceRoot = topLevel;

  # The darwin tarball's Mach-O binaries link only system libraries, so only
  # the Linux build is patched. patchelf 0.19 leaves `t3` segfaulting on start;
  # versionCheckHook fails the build when that breaks.
  nativeBuildInputs =
    lib.optionals isLinux [
      (import ./patchelf-0-16.nix { inherit pkgs; })
      pkgs.autoPatchelfHook
    ]
    ++ [
      pkgs.file
      pkgs.writableTmpDirAsHomeHook
    ];

  # libstdc++, libgcc_s, and libatomic for the Node binary and node-pty; every
  # other library the binaries need is glibc's.
  buildInputs = lib.optional isLinux pkgs.stdenv.cc.cc.lib;

  # `t3` is a Node single-executable application whose bundle lives in the
  # non-allocated `.note.node.sea` section; strip would remove it. patchelf
  # leaves that section intact.
  dontStrip = true;

  # The binary resolves client/, node_modules/, and
  # resource-monitor/<platform>/t3-resource-monitor beside its own real path,
  # so the tree stays together and bin/t3 is a symlink to it. That lookup
  # finds the bundled resource monitor without T3CODE_RESOURCE_MONITOR_PATH.
  installPhase = ''
    runHook preInstall

    # Native addons for musl, and prebuilds for any other platform, would
    # leave autoPatchelf with dependencies glibc does not provide.
    find node_modules -depth -type d -name '*-musl' -exec rm -rf {} +
    find node_modules -type d -path '*/prebuilds/*' -prune ! -name '${platformKey}' -exec rm -rf {} +

    # autoPatchelf skips only ET_EXEC static binaries. On x86_64 the Cursor
    # SDK's rg and cursorsandbox are static-pie (ET_DYN with no interpreter),
    # and any runpath it writes into one leaves it segfaulting. None is written
    # today, as nothing sets appendRunpaths or runtimeDependencies, but that is
    # one attribute away. Set every static-pie file aside here and put it back
    # after autoPatchelf in postFixup. The arm64
    # tarball has none (its rg is ET_EXEC), so the directory must exist even
    # when nothing is set aside.
    # One file(1) run per batch: -0 ends each name with NUL, then ": <type>".
    mkdir -p "$TMPDIR/static-pie"
    find . -type f -exec file -0 -- {} + | while IFS= read -r -d "" path && IFS= read -r type; do
      case $type in
        *'static-pie linked'*) install -Dm755 "$path" "$TMPDIR/static-pie/$path" ;;
      esac
    done

    mkdir -p $out/libexec $out/bin
    cp -r . $out/libexec/t3code
    ln -s $out/libexec/t3code/t3 $out/bin/t3

    runHook postInstall
  '';

  # postFixup runs before the postFixupHooks array the hook registers itself
  # in, so restoring there would precede the patching. The hook is disabled
  # and run here instead, ahead of the restore. On darwin nothing is patched,
  # and file(1) reports no static-pie Mach-O, so nothing was set aside.
  dontAutoPatchelf = true;
  postFixup = lib.optionalString isLinux ''
    autoPatchelf -- "$out"
    (cd "$TMPDIR/static-pie" && find . -type f -print0 | while IFS= read -r -d "" file; do
      install -Dm755 "$file" "$out/libexec/t3code/$file"
    done)
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];

  passthru = { inherit platformKey; };

  meta = {
    description = "Headless T3 Code server and CLI (nightly)";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "t3";
  };
}
