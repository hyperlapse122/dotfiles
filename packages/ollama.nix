{ pkgs, cudaSupport }:
let
  inherit (pkgs) lib;
  release = lib.importJSON ./ollama-release.json;
  asset = release.targets.linux-amd64;
in
pkgs.stdenv.mkDerivation {
  pname = "ollama";
  version = lib.removePrefix "v" release.tag;
  src = pkgs.fetchurl { inherit (asset) url sha256; };

  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
    pkgs.zstd
  ];
  buildInputs = [
    pkgs.stdenv.cc.cc.lib
    pkgs.vulkan-loader
  ];
  # The NVIDIA driver comes from the running system.
  autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];
  dontStrip = true;
  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    tar --zstd -xf "$src" -C "$out" ${
      lib.optionalString (!cudaSupport) "--exclude='lib/ollama/cuda_*' --exclude='lib/ollama/vulkan'"
    }
    ${lib.optionalString cudaSupport ''
      wrapProgram "$out/bin/ollama" --suffix LD_LIBRARY_PATH : "${pkgs.addDriverRunpath.driverLink}/lib"
    ''}
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    HOME="$TMPDIR" OLLAMA_HOST=127.0.0.1:1 "$out/bin/ollama" --version 2>&1 | grep -F -- "$version"
    "$out/lib/ollama/llama-server" --version
    runHook postInstallCheck
  '';
  meta = {
    mainProgram = "ollama";
    platforms = [ "x86_64-linux" ];
  };
}
