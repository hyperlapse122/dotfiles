{
  pkgs,
  backend ? if pkgs.stdenv.hostPlatform.isDarwin then "mlx" else "openrouter",
}:

let
  pins = pkgs.lib.importJSON ./decide-runtime-pins.json;
  fetch =
    name: source:
    pkgs.fetchurl {
      inherit name;
      inherit (source) url sha256;
    };
  darwinLoader = fetch "clef_mlx.py" pins.darwin.loader;
  linuxLoader = fetch "joint_schema_model.py" pins.linux.loader;
  darwinLicense = fetch "clef-mlx-LICENSE" pins.darwin.license;
  linuxLicense = fetch "clef-flash-LICENSE" pins.linux.license;
  clefLocalArchive = fetch "clef-local.tar.gz" pins.linux.clefLocal;
  clefLocal = pkgs.runCommand "clef-local-source-${pins.linux.clefLocal.revision}" { } ''
    mkdir -p "$out"
    tar -xzf ${clefLocalArchive} --strip-components=1 -C "$out"
  '';
  lib = pkgs.lib;
  python = pkgs.python312;
  commonPython = python.withPackages (p: [
    p.aiohttp
    p.jsonschema
  ]);
  # Nixpkgs disables MLX Metal. Keep the publisher's Metal-enabled wheels
  # together in one immutable environment so their relative library paths work.
  wheelManifest = lib.importJSON (./decide-runtime + "/wheels-${backend}.json");
  wheels = map (
    wheel:
    pkgs.fetchurl {
      name = wheel.filename;
      inherit (wheel) url sha256;
    }
  ) wheelManifest.wheels;
  nativePython = pkgs.stdenv.mkDerivation {
    pname = "decide-${backend}-runtime";
    version = "1";
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    nativeBuildInputs = [
      pkgs.uv
      pkgs.makeWrapper
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
      pkgs.glib
    ];
    # The driver is supplied by the running NVIDIA host, not the wheel closure.
    autoPatchelfIgnoreMissingDeps = [ "libcuda.so.1" ];
    installPhase = ''
      runHook preInstall
      export UV_CACHE_DIR="$TMPDIR/uv-cache"
      uv venv --offline --no-python-downloads --python ${python}/bin/python3 "$out"
      mkdir -p "$TMPDIR/wheels"
      for wheel in ${lib.escapeShellArgs wheels}; do
        filename="''${wheel##*/}"
        cp "$wheel" "$TMPDIR/wheels/''${filename#*-}"
      done
      uv pip install --offline --no-deps --link-mode copy --python "$out/bin/python3" \
        "$TMPDIR/wheels/"*.whl
      ${lib.optionalString (backend == "cuda") ''
        for directory in "$out"/lib/python3.12/site-packages/nvidia/*/lib; do
          if [ -d "$directory" ]; then
            addAutoPatchelfSearchPath "$directory"
          fi
        done
        addAutoPatchelfSearchPath "$out/lib/python3.12/site-packages/torch/lib"
        wrapProgram "$out/bin/python" \
          --prefix PYTHONPATH : ${clefLocal}/src \
          --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.stdenv.cc
              pkgs.binutils
            ]
          } \
          --set CC ${lib.getExe' pkgs.stdenv.cc "cc"} \
          --set CXX ${lib.getExe' pkgs.stdenv.cc "c++"}
      ''}
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      export PYTHONDONTWRITEBYTECODE=1
      "$out/bin/python3" ${../tests/decide-runtime.py} \
        ${backend} ${if backend == "mlx" then darwinLoader else linuxLoader}
      runHook postInstallCheck
    '';
    meta = {
      description = "Pinned native Python runtime for Decisions inference";
      platforms = if backend == "mlx" then [ "aarch64-darwin" ] else [ "x86_64-linux" ];
    };
  };
in
assert lib.assertMsg (lib.elem backend [
  "mlx"
  "cuda"
  "openrouter"
]) "Unknown Decisions backend";
{
  inherit pins;
  python = if backend == "openrouter" then commonPython else nativePython;
  loaders = {
    darwin = darwinLoader;
    linux = linuxLoader;
    inherit clefLocal darwinLicense linuxLicense;
  };
}
