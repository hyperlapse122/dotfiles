{
  pkgs,
  backend ? if pkgs.stdenv.hostPlatform.isDarwin then "mlx" else "openrouter",
  openrouterKeyFile ? null,
}:

let
  lib = pkgs.lib;
  runtime = import ./decide-runtime.nix { inherit pkgs backend; };
  model =
    {
      mlx = "mlx-community/clef-flash-8bit";
      cuda = "Cloudflare/clef-flash";
      openrouter = "typesafe/jev-1.14";
    }
    .${backend};
  loader = if backend == "mlx" then runtime.loaders.darwin else runtime.loaders.linux;
  pythonLiteral = value: if value == null then "None" else builtins.toJSON (toString value);
  testPython = pkgs.python312.withPackages (p: [
    p.aiohttp
    p.jsonschema
    p.pillow
  ]);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "decide";
  version = "1";
  src = lib.cleanSource ./decide;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/decide" "$out/bin" "$out/share/licenses/decide"
    cp -R decide "$out/lib/decide/"
    cp NOTICE "$out/share/licenses/decide/NOTICE"
    ${lib.optionalString (backend != "openrouter") ''
      cp ${if backend == "mlx" then runtime.loaders.darwinLicense else runtime.loaders.linuxLicense} \
        "$out/share/licenses/decide/clef-LICENSE"
    ''}
    cat > "$out/lib/decide/decide/_package.py" <<'EOF'
    BACKEND = ${pythonLiteral backend}
    MODEL = ${pythonLiteral model}
    LOADER = ${pythonLiteral (if backend == "openrouter" then null else loader)}
    KEY_FILE = ${pythonLiteral openrouterKeyFile}
    EOF
    makeWrapper ${runtime.python}/bin/python3 "$out/bin/decide" \
      --prefix PYTHONPATH : "$out/lib/decide" --add-flags "-m decide"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/config" PYTHONDONTWRITEBYTECODE=1
    export PYTHONPATH="$out/lib/decide" DECIDE_TEST_CLI="$out/bin/decide"
    mkdir -p "$HOME"
    "$out/bin/decide" --help > /dev/null
    ${testPython}/bin/python3 ${../tests/decide-contract.py}
    ${testPython}/bin/python3 ${../tests/decide-local.py}
    ${testPython}/bin/python3 ${../tests/decide-ipc.py}
    runHook postInstallCheck
  '';
  meta = {
    description = "Human CLI and private Decisions service";
    mainProgram = "decide";
    platforms = lib.platforms.unix;
  };
}
