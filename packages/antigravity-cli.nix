{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./antigravity-cli-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  platform =
    source.platforms.${system}
      or (throw "packages/antigravity-cli-release.json pins no agy release for ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "antigravity-cli";
  inherit (source) version;

  src = pkgs.fetchurl { inherit (platform) url hash; };

  # The tarball holds one bare binary with no top-level directory.
  sourceRoot = ".";

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.writableTmpDirAsHomeHook
  ]
  ++ lib.optional pkgs.stdenv.hostPlatform.isElf pkgs.autoPatchelfHook;

  # The variable holds under any HOME, including the per-provider homes T3 Code
  # sets, where no settings file turns the self-updater off. agy accepts only
  # `true`: with `1` it still starts the updater.
  installPhase = ''
    runHook preInstall

    install -Dm755 antigravity $out/libexec/antigravity-cli/agy
    makeWrapper $out/libexec/antigravity-cli/agy $out/bin/agy \
      --set AGY_CLI_DISABLE_AUTO_UPDATE true

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];
  postInstallCheck = ''
    grep -qxF "export AGY_CLI_DISABLE_AUTO_UPDATE='true'" $out/bin/agy \
      || { echo "bin/agy does not turn the self-updater off" >&2; exit 1; }
  '';

  meta = {
    description = "Google Antigravity command-line coding agent";
    homepage = "https://antigravity.google";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "agy";
  };
}
