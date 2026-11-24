{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./omp-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  platform =
    source.platforms.${system} or (throw "packages/omp-release.json pins no omp binary for ${system}");
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "omp";
  inherit (source) version;

  # Each release asset is one bare executable, not an archive.
  src = pkgs.fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${finalAttrs.version}/${platform.asset}";
    inherit (platform) hash;
  };
  dontUnpack = true;

  # The binary is a Bun executable with its bundle appended to the file, so
  # stripping or any other fixup rewrites it into a bare Bun runtime. It is
  # installed exactly as the release ships it: NixOS runs the dynamically
  # linked Linux build through nix-ld.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/omp
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = lib.optionals isDarwin [
    pkgs.versionCheckHook
    pkgs.writableTmpDirAsHomeHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  # The Linux build needs the host's nix-ld loader, which the build sandbox
  # lacks, so only Darwin runs the binary here. The comparison guards the
  # unmodified install on both systems.
  postInstallCheck = ''
    cmp $src "$out/bin/omp"
  '';

  meta = {
    description = "OMP coding agent";
    homepage = "https://github.com/can1357/oh-my-pi";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "omp";
  };
})
