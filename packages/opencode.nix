{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./opencode-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  platform =
    source.platforms.${system}
      or (throw "packages/opencode-release.json pins no opencode asset for ${system}");
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "opencode";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${finalAttrs.version}/${platform.asset}";
    inherit (platform) hash;
  };

  # Each archive holds one bare binary with no top-level directory.
  sourceRoot = ".";
  nativeBuildInputs = lib.optional (lib.hasSuffix ".zip" platform.asset) pkgs.unzip;

  # The binary is a Bun executable with its script appended to the file, so
  # stripping or any other fixup rewrites it into a bare Bun runtime. It is
  # installed exactly as the release ships it: NixOS runs the dynamically
  # linked Linux build through nix-ld, and no patching step can break.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 opencode $out/bin/opencode

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
    cmp opencode "$out/bin/opencode"
  '';

  meta = {
    description = "Open source coding agent";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "opencode";
  };
})
