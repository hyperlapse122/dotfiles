{ pkgs }:

let
  version = "0.43.0";
  assets = {
    aarch64-darwin = {
      name = "darwin-arm64";
      hash = "05338a8eeddf0b3f9ebf0c87a6c21aedc10685608c68618e1a8483c43eae9c3f";
    };
    x86_64-linux = {
      name = "linux-x64";
      hash = "8e69c9fb662514c9cf36e4911e94e913742ba066e55102486350e049dd847612";
    };
  };
  asset = assets.${pkgs.stdenv.hostPlatform.system};
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "agent-browser";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/vercel-labs/agent-browser/releases/download/v${version}/agent-browser-${asset.name}";
    hash = "sha256:${asset.hash}";
  };
  dontUnpack = true;
  nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.stdenv.cc.cc.lib
    pkgs.openssl
  ];
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/agent-browser"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/agent-browser" --version | grep -F 'agent-browser ${version}'
    "$out/bin/agent-browser" --help >/dev/null
    runHook postInstallCheck
  '';
  meta = {
    description = "Browser automation CLI for coding agents";
    homepage = "https://agent-browser.dev";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "agent-browser";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
