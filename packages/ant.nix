{ pkgs }:
let
  source = builtins.fromJSON (builtins.readFile ./ant-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  asset = source.systems.${system} or (throw "No ant release asset for ${system}");
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ant";
  inherit (source) version;
  src = pkgs.fetchurl {
    url = "https://github.com/anthropics/anthropic-cli/releases/download/v${finalAttrs.version}/ant_${finalAttrs.version}_${asset.asset}";
    inherit (asset) hash;
  };
  nativeBuildInputs = [
    pkgs.installShellFiles
    pkgs.unzip
  ];
  sourceRoot = ".";
  installPhase = ''
    runHook preInstall
    install -Dm755 ant $out/bin/ant
    installShellCompletion --cmd ant \
      --bash <($out/bin/ant @completion bash) \
      --zsh <($out/bin/ant @completion zsh) \
      --fish <($out/bin/ant @completion fish)
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ant --version | grep -F "${finalAttrs.version}"
    runHook postInstallCheck
  '';
  meta = {
    description = "Anthropic CLI for the Claude API";
    homepage = "https://github.com/anthropics/anthropic-cli";
    license = pkgs.lib.licenses.asl20;
    platforms = builtins.attrNames source.systems;
    mainProgram = "ant";
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
})
